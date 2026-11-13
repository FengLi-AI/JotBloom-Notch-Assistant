import Foundation

extension JotBloomStore {
    static let assistantSelect = "SELECT id,title,raw_input,source_kind,chat_session_token,chat_turn_token,status,error_code,result_summary,output_directory,due_at_ms,created_at_ms,updated_at_ms,completed_at_ms,brief_json,plan_json,scope_json FROM assistant_tasks"

    private static func decodeAssistant(_ row: SQLiteStatement) throws -> AssistantTask {
        guard let source = AssistantSource(rawValue: row.text(at: 3)), let status = TaskStatus(rawValue: row.text(at: 6)) else {
            throw PersistenceError.invalidStoredValue(column: "assistant_tasks.status_or_source")
        }
        return .init(id: row.text(at: 0), title: row.text(at: 1), rawInput: row.text(at: 2), source: source,
                     chatSession: row.optionalText(at: 4), chatTurn: row.optionalText(at: 5), status: status,
                     errorCode: row.optionalText(at: 7), resultSummary: row.optionalText(at: 8), outputDirectory: row.optionalText(at: 9),
                     dueAt: row.isNull(at: 10) ? nil : row.int64(at: 10), createdAt: row.int64(at: 11), updatedAt: row.int64(at: 12),
                     completedAt: row.isNull(at: 13) ? nil : row.int64(at: 13),
                     brief: try row.optionalText(at: 14).map { try JSONDecoder().decode(TaskBrief.self, from: Data($0.utf8)) },
                     plan: try row.optionalText(at: 15).map { try JSONDecoder().decode(AssistantPlan.self, from: Data($0.utf8)) },
                     scope: try row.optionalText(at: 16).map { try JSONDecoder().decode(TaskScope.self, from: Data($0.utf8)) })
    }
    public func assistantTasks() async throws -> [AssistantTask] {
        try await performAsync { db in
            let row = try db.prepare(Self.assistantSelect + " ORDER BY updated_at_ms DESC,id", operation: "assistant_tasks")
            var tasks: [AssistantTask] = []
            while try row.stepRow() { tasks.append(try Self.decodeAssistant(row)) }
            return tasks
        }
    }
    public func assistantTask(id: String) async throws -> AssistantTask? {
        try await performAsync { try Self.assistantTask(id, db: $0) }
    }
    static func assistantTask(_ id: String, db: SQLiteConnection) throws -> AssistantTask? {
        let row = try db.prepare(assistantSelect + " WHERE id=?", operation: "assistant_task")
        try row.bind(id, at: 1)
        return try row.stepRow() ? decodeAssistant(row) : nil
    }
    public func assistantTaskLinks() async throws -> [AssistantTaskLink] {
        try await performAsync { db in
            let row = try db.prepare("SELECT chat_turn_token,task_id,title_snapshot FROM assistant_task_links", operation: "assistant_links")
            var links: [AssistantTaskLink] = []
            while try row.stepRow() { links.append(.init(turn: row.text(at: 0), taskID: row.optionalText(at: 1), title: row.text(at: 2))) }
            return links
        }
    }
    public func assistantMaterials(taskID: String) async throws -> [AssistantAttachment] {
        try await performAsync { db in
            let row = try db.prepare("SELECT kind,ref_id,title_snapshot FROM assistant_materials WHERE task_id=? ORDER BY rowid", operation: "assistant_materials")
            try row.bind(taskID, at: 1)
            var values: [AssistantAttachment] = []
            while try row.stepRow() {
                guard let kind = AssistantMaterialKind(rawValue: row.text(at: 0)) else { throw AssistantError.unavailable }
                values.append(.init(kind: kind, reference: row.text(at: 1), title: row.text(at: 2)))
            }
            return values
        }
    }
    public func assistantEvents(taskID: String) async throws -> [AssistantTaskEvent] {
        try await performAsync { db in
            let row = try db.prepare("SELECT id,kind,text,created_at_ms FROM assistant_task_events WHERE task_id=? ORDER BY id DESC", operation: "assistant_events")
            try row.bind(taskID, at: 1)
            var events: [AssistantTaskEvent] = []
            while try row.stepRow() { events.append(.init(id: row.int64(at: 0), taskID: taskID, kind: row.text(at: 1), text: row.text(at: 2), createdAt: row.int64(at: 3))) }
            return events
        }
    }

    // Mutation entry points are internal: AssistantCoordinator owns state changes.
    func createAssistantTask(id: String, input: String, source: AssistantSource, attachments: [AssistantAttachment],
                             session: String? = nil, turn: String? = nil, modelConfigured: Bool = true) async throws -> AssistantTask {
        try await performAsync { db in
            try db.transaction {
                try Self.insertAssistantTask(db, id: id, input: input, source: source, attachments: attachments,
                                             session: session, turn: turn, modelConfigured: modelConfigured)
            }
        }
    }
    static func insertAssistantTask(_ db: SQLiteConnection, id: String, input: String, source: AssistantSource,
                                            attachments: [AssistantAttachment], session: String?, turn: String?,
                                            modelConfigured: Bool) throws -> AssistantTask {
        if let old = try assistantTask(id, db: db) { return old }
        if let turn {
            let link = try db.prepare("SELECT task_id FROM assistant_task_links WHERE chat_turn_token=?", operation: "assistant_once_per_turn")
            try link.bind(turn, at: 1)
            if try link.stepRow() {
                guard let taskID = link.optionalText(at: 0), let existing = try assistantTask(taskID, db: db) else { throw AssistantError.missing }
                return existing
            }
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { throw AssistantError.empty }
        let title = String((trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? attachments.first?.title ?? "新任务").prefix(30))
        let time = chatNow()
        let status: TaskStatus = modelConfigured ? .received : try TaskTransition.next(from: .received, event: .requireConfiguration)
        let insert = try db.prepare("INSERT INTO assistant_tasks(id,title,raw_input,source_kind,chat_session_token,chat_turn_token,status,error_code,created_at_ms,updated_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?)", operation: "create_assistant_task")
        try insert.bind(id, at: 1); try insert.bind(title, at: 2); try insert.bind(input, at: 3)
        try insert.bind(source.rawValue, at: 4); try insert.bind(session, at: 5); try insert.bind(turn, at: 6)
        try insert.bind(status.rawValue, at: 7); try insert.bind(modelConfigured ? nil : "modelNotConfigured", at: 8)
        try insert.bind(time, at: 9); try insert.bind(time, at: 10); try insert.executeDone()
        var seen = Set<String>()
        var materials = attachments
        if let turn { materials.append(.init(kind: .chat, reference: turn, title: "这段对话（最近 3 轮）")) }
        for material in materials where seen.insert(material.id).inserted {
            let row = try db.prepare("INSERT INTO assistant_materials(id,task_id,kind,ref_id,source,title_snapshot,selected) VALUES(?,?,?,?,?,?,?)", operation: "attach_assistant_material")
            try row.bind(UUID().uuidString, at: 1); try row.bind(id, at: 2); try row.bind(material.kind.rawValue, at: 3)
            try row.bind(material.reference, at: 4); try row.bind(material.kind == .chat ? "plan" : "user", at: 5)
            try row.bind(material.title, at: 6); try row.bind(Int64(material.kind == .chat ? 0 : 1), at: 7); try row.executeDone()
        }
        if let turn, let session {
            let link = try db.prepare("INSERT INTO assistant_task_links(chat_turn_token,chat_session_token,task_id,title_snapshot) VALUES(?,?,?,?)", operation: "link_assistant_chat")
            try link.bind(turn, at: 1); try link.bind(session, at: 2); try link.bind(id, at: 3); try link.bind(title, at: 4); try link.executeDone()
        }
        try appendAssistantEvent(db, taskID: id, kind: "received", text: modelConfigured
                                 ? "任务已保存，尚未开始执行。" : "先配置模型，助手才能理解任务。", time: time)
        guard let saved = try assistantTask(id, db: db) else { throw AssistantError.unavailable }
        return saved
    }

    func submitAssistantChat(input: String, attachments: [AssistantAttachment], token: String,
                             expectedSession: String, systemPrompt: String) async throws -> ChatTurn {
        try await performAsync { db in
            try db.transaction {
                let session = try db.prepare("SELECT id FROM chat_sessions WHERE token=? AND slot=1", operation: "assistant_current_chat")
                try session.bind(expectedSession, at: 1)
                guard try session.stepRow() else { throw AssistantError.stale }
                let sessionID = session.int64(at: 0)
                let existing = try db.prepare("SELECT a.id,a.attempt_token,a.created_at_utc_ms,u.content FROM chat_messages a JOIN chat_messages u ON u.session_id=a.session_id AND u.turn_token=a.turn_token AND u.role='user' JOIN assistant_task_links l ON l.chat_turn_token=a.turn_token WHERE a.session_id=? AND a.turn_token=? AND a.role='assistant' AND l.task_id=?", operation: "assistant_chat_idempotency")
                try existing.bind(sessionID, at: 1); try existing.bind(token, at: 2); try existing.bind(token, at: 3)
                if try existing.stepRow() {
                    return .init(id: existing.int64(at: 0), session: expectedSession, token: token, attempt: existing.text(at: 1),
                                 user: existing.text(at: 3), answer: "已转为任务。", timestamp: existing.int64(at: 2), status: .complete)
                }
                let active = try db.prepare("SELECT id FROM chat_messages WHERE state IN ('waiting','streaming') LIMIT 1", operation: "assistant_chat_idle")
                guard try !active.stepRow() else { throw ChatError.busy }
                let text = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "请处理这些资料：" + attachments.map(\.title).joined(separator: "、") : input
                let saved = try Self.insertAssistantTask(db, id: token, input: text, source: .chat, attachments: attachments,
                                                        session: expectedSession, turn: token, modelConfigured: true)
                let attempt = UUID().uuidString, time = Self.chatNow()
                for role in ["user", "assistant"] {
                    let row = try db.prepare("INSERT OR IGNORE INTO chat_messages(session_id,role,content,created_at_utc_ms,turn_token,attempt_token,state) VALUES(?,?,?,?,?,?,'complete')", operation: "assistant_chat_receipt")
                    try row.bind(sessionID, at: 1); try row.bind(role, at: 2); try row.bind(role == "user" ? text : "已转为任务。", at: 3)
                    try row.bind(time, at: 4); try row.bind(token, at: 5); try row.bind(attempt, at: 6); try row.executeDone()
                }
                let touch = try db.prepare("UPDATE chat_sessions SET updated_at_utc_ms=?,system_prompt=COALESCE(system_prompt,?) WHERE id=?", operation: "assistant_chat_touch")
                try touch.bind(time, at: 1); try touch.bind(systemPrompt, at: 2); try touch.bind(sessionID, at: 3); try touch.executeDone()
                let clear = try db.prepare("DELETE FROM assistant_composer_attachments WHERE chat_session_token=?", operation: "consume_assistant_attachments")
                try clear.bind(expectedSession, at: 1); try clear.executeDone()
                try db.execute("DELETE FROM drafts WHERE kind='ai_chat'", operation: "consume_assistant_draft")
                let row = try db.prepare("SELECT id,attempt_token,created_at_utc_ms FROM chat_messages WHERE session_id=? AND turn_token=? AND role='assistant'", operation: "assistant_saved_turn")
                try row.bind(sessionID, at: 1); try row.bind(token, at: 2)
                guard try row.stepRow(), saved.chatTurn == token else { throw AssistantError.stale }
                return .init(id: row.int64(at: 0), session: expectedSession, token: token, attempt: row.text(at: 1), user: text,
                             answer: "已转为任务。", timestamp: row.int64(at: 2), status: .complete)
            }
        }
    }
    func transitionAssistantTask(id: String, event: TaskTransitionEvent, text: String) async throws {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db) else { throw AssistantError.missing }
                let next = try TaskTransition.next(from: task.status, event: event), time = Self.chatNow()
                let row = try db.prepare("UPDATE assistant_tasks SET status=?,updated_at_ms=?,completed_at_ms=CASE WHEN ? THEN ? ELSE NULL END WHERE id=?", operation: "transition_assistant")
                try row.bind(next.rawValue, at: 1); try row.bind(time, at: 2); try row.bind(Int64(next.isTerminal ? 1 : 0), at: 3)
                try row.bind(time, at: 4); try row.bind(id, at: 5); try row.executeDone()
                try Self.appendAssistantEvent(db, taskID: id, kind: next.rawValue, text: text, time: time)
                if next.isTerminal {
                    let cancel = try db.prepare("UPDATE assistant_reminders SET state='cancelled' WHERE task_id=? AND state='pending'", operation: "cancel_task_reminders")
                    try cancel.bind(id, at: 1); try cancel.executeDone()
                }
            }
        }
    }
    func deleteAssistantTask(id: String) async throws {
        try await performAsync { db in
            let row = try db.prepare("DELETE FROM assistant_tasks WHERE id=? AND status IN ('completed','failed')", operation: "delete_assistant")
            try row.bind(id, at: 1); try row.executeDone()
            guard try db.changesCount() == 1 else { throw AssistantError.invalidTransition }
        }
    }
    func recoverAssistantTasks() async throws {
        try await performAsync { db in
            try db.transaction {
                let time = Self.chatNow()
                let rows = try db.prepare("SELECT id FROM assistant_tasks WHERE status IN ('running','queued','understanding')", operation: "assistant_recovery")
                var ids: [String] = []
                while try rows.stepRow() { ids.append(rows.text(at: 0)) }
                for id in ids { try Self.appendAssistantEvent(db, taskID: id, kind: "interrupted", text: "上次处理被中断，已保留进度，等待你决定。", time: time) }
                let update = try db.prepare("UPDATE assistant_tasks SET status='interrupted',updated_at_ms=? WHERE status IN ('running','queued','understanding')", operation: "interrupt_unfinished_tasks")
                try update.bind(time, at: 1); try update.executeDone()
                try db.execute("UPDATE assistant_task_steps SET state='unknown' WHERE state='running' AND task_id IN (SELECT id FROM assistant_tasks WHERE status='interrupted'); UPDATE assistant_questions SET rpc_request_id=NULL WHERE kind='approval' AND answered_at_ms IS NULL", operation: "invalidate_stale_assistant_work")
            }
        }
    }
    static func appendAssistantEvent(_ db: SQLiteConnection, taskID: String, kind: String, text: String, time: Int64) throws {
        let row = try db.prepare("INSERT INTO assistant_task_events(task_id,kind,text,created_at_ms) VALUES(?,?,?,?)", operation: "assistant_event")
        try row.bind(taskID, at: 1); try row.bind(kind, at: 2); try row.bind(text, at: 3); try row.bind(time, at: 4); try row.executeDone()
    }
    public func assistantDraftAttachments(session: String) throws -> [AssistantAttachment] {
        try performSync { db in
            let row = try db.prepare("SELECT payload_json FROM assistant_composer_attachments WHERE chat_session_token=?", operation: "assistant_draft_attachments")
            try row.bind(session, at: 1)
            guard try row.stepRow() else { return [] }
            return try JSONDecoder().decode([AssistantAttachment].self, from: Data(row.text(at: 0).utf8))
        }
    }
    public func saveAssistantDraftAttachments(_ attachments: [AssistantAttachment], session: String) throws {
        try performSync { db in
            let row = try db.prepare("INSERT INTO assistant_composer_attachments(chat_session_token,payload_json) VALUES(?,?) ON CONFLICT(chat_session_token) DO UPDATE SET payload_json=excluded.payload_json", operation: "save_assistant_draft_attachments")
            try row.bind(session, at: 1); try row.bind(String(decoding: JSONEncoder().encode(attachments), as: UTF8.self), at: 2); try row.executeDone()
        }
    }
}
