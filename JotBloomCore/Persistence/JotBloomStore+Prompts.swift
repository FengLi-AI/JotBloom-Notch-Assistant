import Foundation

extension JotBloomStore {
    static let promptColumns = "id,title,content,title_source,created_at_utc_ms,origin_kind,source_clipboard_id,source_application_name,source_bundle_identifier,submission_token,lifecycle_token,title_revision,sort_order,is_favorite"

    public func prompt(id: Int64) async throws -> Prompt? {
        try await performAsync { try Self.findPrompt(id: id, connection: $0) }
    }
    public func promptSynchronously(id: Int64) throws -> Prompt? {
        try performSync { try Self.findPrompt(id: id, connection: $0) }
    }
    public func listPrompts(after: Prompt? = nil, limit: Int = 50, favoritesOnly: Bool = false) async throws -> [Prompt] {
        try await performAsync { connection in
            let query = try connection.prepare("SELECT \(Self.promptColumns) FROM prompts WHERE (? IS NULL OR sort_order < ? OR (sort_order = ? AND id < ?)) AND (\(favoritesOnly ? "is_favorite = 1" : "1")) ORDER BY sort_order DESC,id DESC LIMIT ?", operation: "list_prompts")
            try query.bind(after.map { String($0.id) }, at: 1)
            try query.bind(after?.sortOrder ?? 0, at: 2)
            try query.bind(after?.sortOrder ?? 0, at: 3)
            try query.bind(after?.id ?? 0, at: 4)
            try query.bind(Int64(min(max(limit, 1), 100)), at: 5)
            var result: [Prompt] = []
            while try query.stepRow() { result.append(try Self.decodePrompt(query)) }
            return result
        }
    }
    public func saveInputPrompt(content: String, token: String, timestamp: Int64) async throws -> CrossSourceSaveResult {
        try await performAsync { connection in
            try connection.transaction {
                try PromptText.validate(content)
                let old = try connection.prepare("SELECT id FROM prompts WHERE submission_token = ?", operation: "find_submission")
                try old.bind(token, at: 1)
                if try old.stepRow() { return CrossSourceSaveResult(id: old.int64(at: 0), created: false) }
                let id = try Self.insertPrompt(content: content, origin: "input", sourceID: nil, name: nil, bundle: nil, token: token, timestamp: timestamp, connection: connection)
                try connection.execute("DELETE FROM drafts WHERE kind = 'inspiration'", operation: "consume_prompt_draft")
                return CrossSourceSaveResult(id: id, created: true)
            }
        }
    }
    public func saveClipboard(id: Int64, to target: SaveTarget, timestamp: Int64) async throws -> CrossSourceSaveResult {
        try await performAsync { connection in
            try connection.transaction {
                let source = try connection.prepare("SELECT content_type,text_content,source_application_name,source_bundle_identifier FROM clipboard_items WHERE id = ?", operation: "read_save_source")
                try source.bind(id, at: 1)
                guard try source.stepRow() else { throw PromptError.sourceMissing }
                guard source.text(at: 0) != "image", let content = source.optionalText(at: 1) else { throw PromptError.imageUnsupported }
                try PromptText.validate(content)
                let table = target == .prompt ? "prompts" : "inspirations"
                let old = try connection.prepare("SELECT id FROM \(table) WHERE source_clipboard_id = ?", operation: "find_saved_target")
                try old.bind(id, at: 1)
                if try old.stepRow() { return CrossSourceSaveResult(id: old.int64(at: 0), created: false) }
                let name = source.optionalText(at: 2), bundle = source.optionalText(at: 3)
                let saved: Int64
                if target == .prompt {
                    saved = try Self.insertPrompt(content: content, origin: "clipboard", sourceID: id, name: name, bundle: bundle, token: UUID().uuidString, timestamp: timestamp, connection: connection)
                } else {
                    let title = String((content.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? content).prefix(30))
                    if let existing = try Self.duplicateInspiration(title: title, body: content, origin: "clipboard", connection: connection) {
                        return CrossSourceSaveResult(id: existing, created: false)
                    }
                    let insert = try connection.prepare("INSERT INTO inspirations(title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source,origin_kind,source_clipboard_id,source_application_name,source_bundle_identifier,sort_order) VALUES (?,?,'idea','fallback',?,?,'manual','clipboard',?,?,?,(SELECT COALESCE(MAX(sort_order),0)+1 FROM inspirations))", operation: "save_clipboard_inspiration")
                    try insert.bind(title, at: 1); try insert.bind(content, at: 2)
                    try insert.bind(timestamp, at: 3); try insert.bind(timestamp, at: 4)
                    try insert.bind(id, at: 5); try insert.bind(name, at: 6); try insert.bind(bundle, at: 7)
                    try insert.executeDone(); saved = try connection.lastInsertRowID()
                }
                return CrossSourceSaveResult(id: saved, created: true)
            }
        }
    }
    public func renamePromptSynchronously(id: Int64, title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptError.invalidTitle }
        try performSync { connection in
            let update = try connection.prepare("UPDATE prompts SET title = ?, title_source = 'user', title_revision = title_revision + 1 WHERE id = ?", operation: "rename_prompt")
            try update.bind(title, at: 1); try update.bind(id, at: 2); try update.executeDone()
            guard try connection.changesCount() == 1 else { throw PromptError.missing }
        }
    }
    public func savePromptEdits(id: Int64, title: String, content: String, asNew: Bool, token: String, timestamp: Int64) async throws -> Int64 {
        try PromptText.validate(content)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptError.invalidTitle }
        return try await performAsync { connection in
            try connection.transaction {
                guard try Self.findPrompt(id: id, connection: connection) != nil else { throw PromptError.missing }
                var target = id
                if asNew {
                    let old = try connection.prepare("SELECT id FROM prompts WHERE submission_token = ?", operation: "find_save_as_submission")
                    try old.bind(token, at: 1)
                    if try old.stepRow() { return old.int64(at: 0) }
                    target = try Self.insertPrompt(content: content, origin: "input", sourceID: nil, name: nil, bundle: nil, token: token, timestamp: timestamp, connection: connection)
                }
                let update = try connection.prepare("UPDATE prompts SET title = ?, content = ?, title_source = 'user', title_revision = title_revision + 1 WHERE id = ?", operation: "save_prompt_edits")
                try update.bind(title, at: 1); try update.bind(content, at: 2); try update.bind(target, at: 3)
                try update.executeDone()
                return target
            }
        }
    }
    public func deletePrompt(id: Int64) async throws -> Prompt {
        try await performAsync { connection in
            try connection.transaction {
                guard let prompt = try Self.findPrompt(id: id, connection: connection) else { throw PromptError.missing }
                let statement = try connection.prepare("DELETE FROM prompts WHERE id = ?", operation: "delete_prompt")
                try statement.bind(id, at: 1); try statement.executeDone()
                return prompt
            }
        }
    }
    /// Returns false if the content was restored without its original source association.
    public func restorePrompt(_ prompt: Prompt) async throws -> Bool {
        try await performAsync { connection in
            try connection.transaction {
                var sourceID = prompt.sourceClipboardID
                if let id = sourceID {
                    let available = try connection.prepare("SELECT id FROM clipboard_items WHERE id = ? AND NOT EXISTS(SELECT 1 FROM prompts WHERE source_clipboard_id = ?)", operation: "restore_prompt_source")
                    try available.bind(id, at: 1); try available.bind(id, at: 2)
                    if try !available.stepRow() { sourceID = nil }
                }
                let insert = try connection.prepare("INSERT INTO prompts(\(Self.promptColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", operation: "restore_prompt")
                try insert.bind(prompt.id, at: 1); try insert.bind(prompt.title, at: 2); try insert.bind(prompt.content, at: 3)
                try insert.bind(prompt.titleSource.rawValue, at: 4); try insert.bind(prompt.createdAtUTCms, at: 5)
                try insert.bind(prompt.originKind, at: 6); try insert.bind(sourceID.map(String.init), at: 7)
                try insert.bind(prompt.sourceApplicationName, at: 8); try insert.bind(prompt.sourceBundleIdentifier, at: 9)
                try insert.bind(prompt.submissionToken, at: 10); try insert.bind(UUID().uuidString, at: 11)
                try insert.bind(prompt.titleRevision, at: 12); try insert.bind(prompt.sortOrder, at: 13); try insert.bind(Int64(prompt.isFavorite ? 1 : 0), at: 14); try insert.executeDone()
                return sourceID == prompt.sourceClipboardID
            }
        }
    }
    public func applyPromptTitleSynchronously(_ title: String, expected: Prompt) throws -> Bool {
        try performSync { connection in
            let update = try connection.prepare("UPDATE prompts SET title = ?, title_source = 'ai', title_revision = title_revision + 1 WHERE id = ? AND lifecycle_token = ? AND title_revision = ? AND title_source = 'fallback'", operation: "apply_prompt_title")
            try update.bind(title, at: 1); try update.bind(expected.id, at: 2)
            try update.bind(expected.lifecycleToken, at: 3); try update.bind(expected.titleRevision, at: 4)
            try update.executeDone(); return try connection.changesCount() == 1
        }
    }
    static func findPrompt(id: Int64, connection: SQLiteConnection) throws -> Prompt? {
        let query = try connection.prepare("SELECT \(promptColumns) FROM prompts WHERE id = ?", operation: "read_prompt")
        try query.bind(id, at: 1)
        return try query.stepRow() ? decodePrompt(query) : nil
    }
    static func decodePrompt(_ query: SQLiteStatement) throws -> Prompt {
        guard let source = ValueSource(rawValue: query.text(at: 3)) else { throw PersistenceError.invalidStoredValue(column: "prompts.title_source") }
        return Prompt(id: query.int64(at: 0), title: query.text(at: 1), content: query.text(at: 2), titleSource: source,
                      createdAtUTCms: query.int64(at: 4), originKind: query.text(at: 5), sourceClipboardID: query.isNull(at: 6) ? nil : query.int64(at: 6),
                      sourceApplicationName: query.optionalText(at: 7), sourceBundleIdentifier: query.optionalText(at: 8),
                      submissionToken: query.text(at: 9), lifecycleToken: query.text(at: 10), titleRevision: query.int64(at: 11), sortOrder: query.int64(at: 12), isFavorite: query.int64(at: 13) == 1)
    }
    private static func insertPrompt(content: String, origin: String, sourceID: Int64?, name: String?, bundle: String?, token: String, timestamp: Int64, connection: SQLiteConnection) throws -> Int64 {
        let insert = try connection.prepare("INSERT INTO prompts(title,content,title_source,created_at_utc_ms,origin_kind,source_clipboard_id,source_application_name,source_bundle_identifier,submission_token,lifecycle_token,sort_order) VALUES (?,?,'fallback',?,?,?,?,?,?,?,(SELECT COALESCE(MAX(sort_order),0)+1 FROM prompts))", operation: "insert_prompt")
        try insert.bind(PromptText.fallback(content), at: 1); try insert.bind(content, at: 2)
        try insert.bind(timestamp, at: 3); try insert.bind(origin, at: 4); try insert.bind(sourceID.map(String.init), at: 5)
        try insert.bind(name, at: 6); try insert.bind(bundle, at: 7); try insert.bind(token, at: 8)
        try insert.bind(UUID().uuidString, at: 9); try insert.executeDone()
        return try connection.lastInsertRowID()
    }
}
