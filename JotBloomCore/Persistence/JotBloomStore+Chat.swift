import Foundation

extension JotBloomStore {
    private static let chatSelect = """
        SELECT a.id,s.token,a.turn_token,a.attempt_token,u.content,a.content,u.created_at_utc_ms,a.state,a.error_code
        FROM chat_messages a JOIN chat_sessions s ON s.id=a.session_id
        JOIN chat_messages u ON u.session_id=a.session_id AND u.turn_token=a.turn_token AND u.role='user'
        WHERE a.role='assistant' AND s.slot=1
        """

    private static func decodeChat(_ row: SQLiteStatement) throws -> ChatTurn {
        guard let status = ChatStatus(rawValue: row.text(at: 7)) else { throw ChatError.storage }
        return ChatTurn(id: row.int64(at: 0), session: row.text(at: 1), token: row.text(at: 2), attempt: row.text(at: 3),
                        user: row.text(at: 4), answer: row.text(at: 5), timestamp: row.int64(at: 6), status: status, errorCode: row.optionalText(at: 8))
    }
    private static func ensureChat(_ db: SQLiteConnection) throws -> (Int64, String) {
        let current = try db.prepare("SELECT id,token FROM chat_sessions WHERE slot=1", operation: "current_chat_session")
        if try current.stepRow() { return (current.int64(at: 0), current.text(at: 1)) }
        let insert = try db.prepare("INSERT OR IGNORE INTO chat_sessions(slot,token,updated_at_utc_ms) VALUES(1,?,?)", operation: "ensure_chat")
        try insert.bind(UUID().uuidString, at: 1); try insert.bind(chatNow(), at: 2); try insert.executeDone()
        let row = try db.prepare("SELECT id,token FROM chat_sessions WHERE slot=1", operation: "read_chat_session")
        guard try row.stepRow() else { throw ChatError.storage }
        return (row.int64(at: 0), row.text(at: 1))
    }
    static func chatNow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public func chatPage(before: Int64? = nil, recover: Bool = false) async throws -> ChatPage {
        try await performAsync { db in
            _ = try Self.ensureChat(db)
            if recover { try db.execute("UPDATE chat_messages SET state='interrupted',error_code='interrupted' WHERE role='assistant' AND state IN ('waiting','streaming')", operation: "recover_chat") }
            let query = try db.prepare(Self.chatSelect + (before == nil ? "" : " AND a.id < ?") + " ORDER BY a.id DESC LIMIT 51", operation: "chat_page")
            if let before { try query.bind(before, at: 1) }
            var turns: [ChatTurn] = []
            while try query.stepRow() { turns.append(try Self.decodeChat(query)) }
            let more = turns.count > 50
            if more { turns.removeLast() }
            return ChatPage(turns: turns.reversed(), hasMore: more)
        }
    }

    public func chatContext() async throws -> [ChatTurn] {
        try await performAsync { db in
            let query = try db.prepare(Self.chatSelect + " AND a.state='complete' ORDER BY a.id DESC", operation: "chat_context")
            var turns: [ChatTurn] = [], budget = 0
            while try query.stepRow() {
                let turn = try Self.decodeChat(query)
                turns.append(turn); budget += ChatContext.estimate(turn.user) + ChatContext.estimate(turn.answer)
                if turns.count >= 3 && budget > 8000 { break }
            }
            return turns.reversed()
        }
    }

    public func submitChat(_ text: String, token: String, source: DraftKind, systemPrompt: String = ChatContext.system) async throws -> ChatTurn {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.empty }
        return try await performAsync { db in
            try db.transaction {
                let existing = try db.prepare(Self.chatSelect + " AND a.turn_token=?", operation: "chat_submission_once")
                try existing.bind(token, at: 1)
                if try existing.stepRow() { return try Self.decodeChat(existing) }
                let active = try db.prepare("SELECT id FROM chat_messages WHERE state IN ('waiting','streaming') LIMIT 1", operation: "chat_active")
                guard try !active.stepRow() else { throw ChatError.busy }
                let (sessionID, session) = try Self.ensureChat(db)
                try Self.freezeChatPrompt(db, prompt: systemPrompt)
                let attempt = UUID().uuidString, timestamp = Self.chatNow()
                for role in ["user", "assistant"] {
                    let insert = try db.prepare("INSERT INTO chat_messages(session_id,role,content,created_at_utc_ms,turn_token,attempt_token,state) VALUES(?,?,?,?,?,?,?)", operation: "submit_chat")
                    try insert.bind(sessionID, at: 1); try insert.bind(role, at: 2); try insert.bind(role == "user" ? text : "", at: 3)
                    try insert.bind(timestamp, at: 4); try insert.bind(token, at: 5); try insert.bind(attempt, at: 6)
                    try insert.bind(role == "user" ? "complete" : "waiting", at: 7); try insert.executeDone()
                }
                let id = try db.lastInsertRowID()
                let clear = try db.prepare("DELETE FROM drafts WHERE kind=?", operation: "consume_chat_draft")
                try clear.bind(source.rawValue, at: 1); try clear.executeDone()
                return ChatTurn(id: id, session: session, token: token, attempt: attempt, user: text, answer: "", timestamp: timestamp, status: .waiting)
            }
        }
    }

    public func retryChat(_ turn: ChatTurn) async throws -> ChatTurn {
        try await performAsync { db in
            let attempt = UUID().uuidString
            let update = try db.prepare("""
                UPDATE chat_messages SET attempt_token=?,state='waiting',error_code=NULL
                WHERE id=? AND attempt_token=? AND state IN ('stopped','failed','interrupted','length')
                AND id=(SELECT MAX(m.id) FROM chat_messages m WHERE m.session_id=chat_messages.session_id)
                AND session_id=(SELECT id FROM chat_sessions WHERE token=? AND slot=1)
                AND NOT EXISTS(SELECT 1 FROM chat_messages WHERE state IN ('waiting','streaming'))
                """, operation: "retry_chat")
            try update.bind(attempt, at: 1); try update.bind(turn.id, at: 2); try update.bind(turn.attempt, at: 3); try update.bind(turn.session, at: 4); try update.executeDone()
            guard try db.changesCount() == 1 else { throw ChatError.stale }
            var result = turn; result.attempt = attempt; result.status = .waiting; result.errorCode = nil
            return result
        }
    }

    public func updateChat(_ turn: ChatTurn) async throws {
        try await performAsync { db in
          try db.transaction {
            let update = try db.prepare("""
                UPDATE chat_messages SET content=?,state=?,error_code=?
                WHERE id=? AND attempt_token=? AND state IN ('waiting','streaming')
                AND session_id=(SELECT id FROM chat_sessions WHERE token=? AND slot=1)
                """, operation: "update_chat")
            try update.bind(turn.answer, at: 1); try update.bind(turn.status.rawValue, at: 2); try update.bind(turn.errorCode, at: 3)
            try update.bind(turn.id, at: 4); try update.bind(turn.attempt, at: 5); try update.bind(turn.session, at: 6); try update.executeDone()
            guard try db.changesCount() == 1 else { throw ChatError.stale }
            let touch = try db.prepare("UPDATE chat_sessions SET updated_at_utc_ms=? WHERE token=?", operation: "touch_chat")
            try touch.bind(Self.chatNow(), at: 1); try touch.bind(turn.session, at: 2); try touch.executeDone()
          }
        }
    }

    public func newChat() async throws {
        try await performAsync { db in
            try db.transaction {
                let active = try db.prepare("SELECT id FROM chat_messages WHERE state IN ('waiting','streaming') LIMIT 1", operation: "check_chat_reset")
                guard try !active.stepRow() else { throw ChatError.busy }
                let empty = try db.prepare("""
                    SELECT id FROM chat_sessions WHERE slot=1
                    AND NOT EXISTS(SELECT 1 FROM chat_messages WHERE session_id=chat_sessions.id)
                    AND NOT EXISTS(SELECT 1 FROM drafts WHERE kind='ai_chat' AND length(trim(content,char(32)||char(9)||char(10)||char(13)))>0)
                    """, operation: "reuse_empty_chat")
                if try empty.stepRow() { return }
                try Self.archiveCurrentDraft(db)
                try db.execute("UPDATE chat_sessions SET slot=NULL WHERE slot=1; DELETE FROM drafts WHERE kind='ai_chat';", operation: "archive_current_chat")
                _ = try Self.ensureChat(db)
            }
        }
    }

    private static func archiveCurrentDraft(_ db: SQLiteConnection) throws {
        try db.execute("UPDATE chat_sessions SET draft=COALESCE((SELECT content FROM drafts WHERE kind='ai_chat'),'') WHERE slot=1", operation: "archive_chat_draft")
    }

    public func chatSessions() async throws -> [ChatSession] {
        try await performAsync { db in
            _ = try Self.ensureChat(db)
            let row = try db.prepare("""
                SELECT s.token,COALESCE(NULLIF(s.title,''),
                    (SELECT substr(content,1,24) FROM chat_messages WHERE session_id=s.id AND role='user' ORDER BY id LIMIT 1),'新对话'),
                    s.updated_at_utc_ms,COALESCE(s.slot,0)
                FROM chat_sessions s WHERE EXISTS(SELECT 1 FROM chat_messages WHERE session_id=s.id)
                    OR (s.slot=1 AND EXISTS(SELECT 1 FROM drafts WHERE kind='ai_chat' AND length(trim(content,char(32)||char(9)||char(10)||char(13)))>0))
                    OR (s.slot IS NULL AND length(trim(s.draft,char(32)||char(9)||char(10)||char(13)))>0)
                ORDER BY s.updated_at_utc_ms DESC,s.id DESC
                """, operation: "chat_sessions")
            var result: [ChatSession] = []
            while try row.stepRow() {
                result.append(ChatSession(id: row.text(at: 0), title: row.text(at: 1), timestamp: row.int64(at: 2), isCurrent: row.int64(at: 3) == 1))
            }
            return result
        }
    }

    public func selectChat(_ token: String) async throws {
        try await performAsync { db in
            try db.transaction {
                try Self.requireIdleChat(db)
                let target = try db.prepare("SELECT slot,draft FROM chat_sessions WHERE token=?", operation: "select_chat_target")
                try target.bind(token, at: 1)
                guard try target.stepRow() else { throw ChatError.stale }
                if target.int64(at: 0) == 1 { return }
                let text = target.text(at: 1)
                try Self.archiveCurrentDraft(db)
                // Only discard the blank session being left, never historical records or drafts.
                try db.execute("DELETE FROM chat_sessions WHERE slot=1 AND length(trim(draft,char(32)||char(9)||char(10)||char(13)))=0 AND NOT EXISTS(SELECT 1 FROM chat_messages WHERE session_id=chat_sessions.id)", operation: "discard_blank_session")
                try db.execute("UPDATE chat_sessions SET slot=NULL WHERE slot=1", operation: "leave_chat")
                let activate = try db.prepare("UPDATE chat_sessions SET slot=1,draft='' WHERE token=?", operation: "activate_chat")
                try activate.bind(token, at: 1); try activate.executeDone()
                try db.execute("DELETE FROM drafts WHERE kind='ai_chat'", operation: "replace_chat_draft")
                let draft = try db.prepare("INSERT INTO drafts(kind,content,updated_at_utc_ms) VALUES('ai_chat',?,?)", operation: "restore_chat_draft")
                try draft.bind(text, at: 1); try draft.bind(Self.chatNow(), at: 2); try draft.executeDone()
            }
        }
    }

    private static func requireIdleChat(_ db: SQLiteConnection) throws {
        let row = try db.prepare("SELECT 1 FROM chat_messages WHERE state IN ('waiting','streaming') LIMIT 1", operation: "check_chat_idle")
        guard try !row.stepRow() else { throw ChatError.busy }
    }

    public func renameChat(_ token: String, title: String) async throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ChatError.empty }
        try await performAsync { db in
            let update = try db.prepare("UPDATE chat_sessions SET title=? WHERE token=?", operation: "rename_chat")
            try update.bind(name, at: 1); try update.bind(token, at: 2); try update.executeDone()
            guard try db.changesCount() == 1 else { throw ChatError.stale }
        }
    }

    public func deleteChat(_ token: String) async throws {
        try await performAsync { db in
            try db.transaction {
                try Self.requireIdleChat(db)
                let row = try db.prepare("SELECT COALESCE(slot,0) FROM chat_sessions WHERE token=?", operation: "delete_chat_target")
                try row.bind(token, at: 1)
                guard try row.stepRow() else { throw ChatError.stale }
                let current = row.int64(at: 0) == 1
                let remove = try db.prepare("DELETE FROM chat_sessions WHERE token=?", operation: "delete_chat")
                try remove.bind(token, at: 1); try remove.executeDone()
                if current {
                    try db.execute("DELETE FROM drafts WHERE kind='ai_chat'; UPDATE chat_sessions SET slot=1 WHERE id=(SELECT id FROM chat_sessions ORDER BY updated_at_utc_ms DESC,id DESC LIMIT 1);", operation: "restore_recent_chat")
                    try db.execute("INSERT INTO drafts(kind,content,updated_at_utc_ms) SELECT 'ai_chat',draft,updated_at_utc_ms FROM chat_sessions WHERE slot=1; UPDATE chat_sessions SET draft='' WHERE slot=1;", operation: "restore_recent_draft")
                    _ = try Self.ensureChat(db)
                }
            }
        }
    }

    private static func freezeChatPrompt(_ db: SQLiteConnection, prompt: String) throws {
        let update = try db.prepare("UPDATE chat_sessions SET system_prompt=? WHERE slot=1 AND system_prompt IS NULL", operation: "freeze_chat_prompt")
        try update.bind(prompt, at: 1); try update.executeDone()
    }
    public func currentChatIdentity() async throws -> String {
        try await performAsync { try Self.ensureChat($0).1 }
    }
    public func chatSystemPrompt(default value: String) async throws -> String {
        try await performAsync { db in
            _ = try Self.ensureChat(db)
            let row = try db.prepare("SELECT system_prompt FROM chat_sessions WHERE slot=1", operation: "read_chat_prompt")
            guard try row.stepRow() else { throw ChatError.storage }
            return row.optionalText(at: 0) ?? value
        }
    }
    public func persistChatDraftSynchronously(_ content: String, prompt: String) throws {
        try performSync { db in
          try db.transaction {
            _ = try Self.ensureChat(db)
            let row = try db.prepare("INSERT INTO drafts(kind,content,updated_at_utc_ms) VALUES('ai_chat',?,?) ON CONFLICT(kind) DO UPDATE SET content=excluded.content,updated_at_utc_ms=excluded.updated_at_utc_ms", operation: "persist_chat_draft")
            try row.bind(content, at: 1); try row.bind(Self.chatNow(), at: 2); try row.executeDone()
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try Self.freezeChatPrompt(db, prompt: prompt) }
          }
        }
    }
    public func summaryContext(recentOnly: Bool) async throws -> [ChatTurn] {
        try await performAsync { db in
            let rows = try db.prepare(Self.chatSelect + " AND a.state='complete' ORDER BY a.id DESC" + (recentOnly ? " LIMIT 3" : ""), operation: "summary_context")
            var turns: [ChatTurn] = []; var tokens = 0
            while try rows.stepRow() {
                let row = try Self.decodeChat(rows); tokens += ChatContext.estimate(row.user) + ChatContext.estimate(row.answer) + 12
                guard tokens <= 7000 else { throw ChatError.tooLong }
                turns.append(row)
            }
            return turns.reversed()
        }
    }

    public func saveChatSummary(title: String, body: String, session: String) async throws -> Int64 {
        guard body.count <= 100_000 else { throw ChatError.tooLong }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 80,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.empty }
        return try await performAsync { db in
            try db.transaction {
                let current = try Self.ensureChat(db)
                guard current.1 == session else { throw ChatError.stale }
                guard try Self.duplicateInspiration(title: title, body: body, origin: "ai_chat", connection: db) == nil else { throw PromptError.duplicateInspiration }
                let row = try db.prepare("INSERT INTO inspirations(title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source,origin_kind,sort_order,title_source) VALUES(?,?,'idea','fallback',?,?,'ai_chat','ai_chat',(SELECT COALESCE(MAX(sort_order),0)+1 FROM inspirations),'user')", operation: "save_chat_summary")
                let now = Self.chatNow()
                try row.bind(title, at: 1); try row.bind(body, at: 2); try row.bind(now, at: 3); try row.bind(now, at: 4); try row.executeDone()
                return try db.lastInsertRowID()
            }
        }
    }
}
