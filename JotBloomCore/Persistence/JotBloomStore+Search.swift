import Foundation

extension JotBloomStore {
    public func searchAll(query rawQuery: String) async throws -> GlobalSearchSnapshot {
        guard let query = SearchTextMatcher.normalizedQuery(rawQuery) else {
            return .empty
        }
        return try await performAsync {
            try Self.searchAll(query: query, connection: $0)
        }
    }

    public func searchAllSynchronously(
        query rawQuery: String
    ) throws -> GlobalSearchSnapshot {
        guard let query = SearchTextMatcher.normalizedQuery(rawQuery) else {
            return .empty
        }
        return try performSync {
            try Self.searchAll(query: query, connection: $0)
        }
    }

    public func searchableClipboardText(id: Int64) async throws -> String? {
        try await performAsync {
            try Self.searchableClipboardText(id: id, connection: $0)
        }
    }

    public func searchableClipboardTextSynchronously(id: Int64) throws -> String? {
        try performSync {
            try Self.searchableClipboardText(id: id, connection: $0)
        }
    }

    private static func searchAll(
        query: String,
        connection: SQLiteConnection
    ) throws -> GlobalSearchSnapshot {
        GlobalSearchSnapshot(
            clipboard: try searchClipboard(query: query, connection: connection),
            prompts: try searchPrompts(query: query, connection: connection),
            inspirations: try searchInspirations(query: query, connection: connection)
        )
    }

    private static func searchPrompts(query: String, connection: SQLiteConnection) throws -> [GlobalSearchResult] {
        let statement = try connection.prepare("SELECT id,title,content,created_at_utc_ms FROM prompts ORDER BY created_at_utc_ms DESC,id DESC", operation: "search_prompts")
        var results: [GlobalSearchResult] = []
        while try statement.stepRow() {
            guard let segments = SearchTextMatcher.segments(in: statement.text(at: 1), matching: query)
                ?? SearchTextMatcher.segments(in: statement.text(at: 2), matching: query) else { continue }
            results.append(GlobalSearchResult(id: SearchResultID(source: .prompt, recordID: statement.int64(at: 0)), source: .prompt,
                                              leadingKind: .text, segments: segments, timestampUTCms: statement.int64(at: 3),
                                              accessibilityContext: "提示词库，\(segments.map(\.text).joined())"))
        }
        return results
    }

    public func searchablePromptText(id: Int64) async throws -> String? {
        try await prompt(id: id)?.content
    }

    private static func searchClipboard(
        query: String,
        connection: SQLiteConnection
    ) throws -> [GlobalSearchResult] {
        let statement = try connection.prepare(
            """
            SELECT id, content_type, text_content, copied_at_utc_ms
            FROM clipboard_items
            WHERE content_type IN ('text', 'link')
            ORDER BY copied_at_utc_ms DESC, id DESC
            """,
            operation: "search_clipboard"
        )
        var results: [GlobalSearchResult] = []
        while try statement.stepRow() {
            let identifier = statement.int64(at: 0)
            guard let type = ClipboardContentType(rawValue: statement.text(at: 1)),
                  type == .text || type == .link else {
                throw PersistenceError.invalidStoredValue(
                    column: "clipboard_items.content_type"
                )
            }
            guard let text = statement.optionalText(at: 2) else {
                throw PersistenceError.invalidStoredValue(
                    column: "clipboard_items.text_content"
                )
            }
            guard let segments = SearchTextMatcher.segments(
                in: text,
                matching: query
            ) else {
                continue
            }
            let result = GlobalSearchResult(
                id: SearchResultID(source: .clipboard, recordID: identifier),
                source: .clipboard,
                leadingKind: type == .link ? .link : .text,
                segments: segments,
                timestampUTCms: statement.int64(at: 3),
                accessibilityContext: "剪贴板历史，\(segments.map(\.text).joined())"
            )
            results.append(result)
        }
        return results
    }

    private static func searchInspirations(
        query: String,
        connection: SQLiteConnection
    ) throws -> [GlobalSearchResult] {
        let statement = try connection.prepare(
            """
            SELECT id, title, body, created_at_utc_ms
            FROM inspirations
            ORDER BY sort_order DESC, id DESC
            """,
            operation: "search_inspirations"
        )
        var results: [GlobalSearchResult] = []
        while try statement.stepRow() {
            let identifier = statement.int64(at: 0)
            let title = statement.text(at: 1)
            let body = statement.text(at: 2)
            let segments = SearchTextMatcher.segments(
                in: title,
                matching: query
            ) ?? SearchTextMatcher.segments(in: body, matching: query)
            guard let segments else { continue }
            let displayTitle = title.isEmpty ? "无标题" : title
            results.append(
                GlobalSearchResult(
                    id: SearchResultID(
                        source: .inspiration,
                        recordID: identifier
                    ),
                    source: .inspiration,
                    leadingKind: .inspiration,
                    segments: segments,
                    timestampUTCms: statement.int64(at: 3),
                    accessibilityContext: "灵感库，\(displayTitle)，\(segments.map(\.text).joined())"
                )
            )
        }
        return results
    }

    private static func searchableClipboardText(
        id: Int64,
        connection: SQLiteConnection
    ) throws -> String? {
        let statement = try connection.prepare(
            """
            SELECT text_content
            FROM clipboard_items
            WHERE id = ? AND content_type IN ('text', 'link')
            LIMIT 1
            """,
            operation: "read_search_clipboard_text"
        )
        try statement.bind(id, at: 1)
        guard try statement.stepRow() else { return nil }
        guard let text = statement.optionalText(at: 0) else {
            throw PersistenceError.invalidStoredValue(
                column: "clipboard_items.text_content"
            )
        }
        return text
    }
}
