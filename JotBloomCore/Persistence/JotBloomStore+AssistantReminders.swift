import Foundation

extension JotBloomStore {
    public func assistantReminders() async throws -> [AssistantReminder] {
        try await performAsync { db in
            let row = try db.prepare("SELECT r.id,r.task_id,t.title,r.fire_at_ms,r.state,r.origin FROM assistant_reminders r JOIN assistant_tasks t ON t.id=r.task_id WHERE t.status NOT IN ('completed','cancelled','failed') AND r.state IN ('pending','delivered','missed') ORDER BY r.fire_at_ms,r.id", operation: "assistant_reminders")
            var values: [AssistantReminder] = []
            while try row.stepRow() { values.append(.init(id: row.text(at: 0), taskID: row.text(at: 1), title: row.text(at: 2), fireAt: row.int64(at: 3), state: row.text(at: 4), origin: AssistantReminderOrigin(rawValue: row.text(at: 5)) ?? .auto)) }; return values
        }
    }
    func deliverAssistantReminders(now: Int64, missed: Bool) async throws -> [AssistantReminder] {
        try await performAsync { db in
            try db.transaction {
                let row = try db.prepare("SELECT r.id,r.task_id,t.title,r.fire_at_ms,r.origin FROM assistant_reminders r JOIN assistant_tasks t ON t.id=r.task_id WHERE r.state='pending' AND r.fire_at_ms<=? AND t.status NOT IN ('completed','cancelled','failed') ORDER BY r.fire_at_ms", operation: "due_assistant_reminders")
                try row.bind(now, at: 1); var result: [AssistantReminder] = []
                while try row.stepRow() { result.append(.init(id: row.text(at: 0), taskID: row.text(at: 1), title: row.text(at: 2), fireAt: row.int64(at: 3), state: missed ? "missed" : "delivered", origin: AssistantReminderOrigin(rawValue: row.text(at: 4)) ?? .auto)) }
                for reminder in result {
                    let update = try db.prepare("UPDATE assistant_reminders SET state=?,delivered_at_ms=? WHERE id=? AND state='pending'", operation: "deliver_assistant_reminder")
                    try update.bind(reminder.state, at: 1); try update.bind(now, at: 2); try update.bind(reminder.id, at: 3); try update.executeDone()
                    try Self.appendAssistantEvent(db, taskID: reminder.taskID, kind: "reminder", text: (missed ? "错过提醒：" : "到点提醒：") + AssistantDates.text(reminder.fireAt), time: now)
                }
                return result
            }
        }
    }
    func resolveAssistantReminders(ids: [String], snooze: Bool, now: Int64) async throws {
        try await performAsync { db in
            try db.transaction {
                var tasks: Set<String> = []
                for id in Set(ids) {
                    let row = try db.prepare("SELECT task_id FROM assistant_reminders WHERE id=? AND state IN ('missed','delivered')", operation: "resolve_reminder_read")
                    try row.bind(id, at: 1); guard try row.stepRow() else { continue }
                    let taskID = row.text(at: 0); tasks.insert(taskID)
                    let update = try db.prepare("UPDATE assistant_reminders SET state=?,fire_at_ms=CASE WHEN ? THEN ? ELSE fire_at_ms END,origin=CASE WHEN ? THEN 'user' ELSE origin END,delivered_at_ms=CASE WHEN ? THEN NULL ELSE delivered_at_ms END WHERE id=?", operation: "resolve_reminder")
                    try update.bind(snooze ? "pending" : "acknowledged", at: 1); try update.bind(Int64(snooze ? 1 : 0), at: 2)
                    try update.bind(now + 3_600_000, at: 3); try update.bind(Int64(snooze ? 1 : 0), at: 4); try update.bind(Int64(snooze ? 1 : 0), at: 5); try update.bind(id, at: 6); try update.executeDone()
                }
                for id in tasks {
                    let pending = try db.prepare("SELECT id FROM assistant_reminders WHERE task_id=? AND state IN ('pending','delivered','missed') LIMIT 1", operation: "remaining_reminders")
                    try pending.bind(id, at: 1)
                    if try !pending.stepRow() {
                        let complete = try db.prepare("UPDATE assistant_tasks SET status='completed',completed_at_ms=?,updated_at_ms=? WHERE id=? AND status='scheduled'", operation: "complete_reminder_task")
                        try complete.bind(now, at: 1); try complete.bind(now, at: 2); try complete.bind(id, at: 3); try complete.executeDone()
                    }
                    try Self.appendAssistantEvent(db, taskID: id, kind: "reminderResolved", text: snooze ? "已推迟 1 小时。" : "你点了知道了。", time: now)
                }
            }
        }
    }
    /// Chat receipt and routed mutation commit together; no duplicate user row or partial note/task.
    func commitAssistantRoute(turn: ChatTurn, intent: AssistantIntent) async throws -> AssistantChatResult {
        try await performAsync { db in
            try db.transaction {
                let check = try db.prepare("SELECT state,attempt_token FROM chat_messages WHERE id=?", operation: "route_current_turn")
                try check.bind(turn.id, at: 1)
                guard try check.stepRow(), check.text(at: 0) == "waiting", check.text(at: 1) == turn.attempt else { throw ChatError.stale }
                var row = turn; var noteID: Int64?
                switch intent {
                case .chat: return .chat
                case .task:
                    _ = try Self.insertAssistantTask(db, id: turn.token, input: turn.user, source: .chat, attachments: [], session: turn.session, turn: turn.token, modelConfigured: true)
                    row.answer = "已转为任务。"
                case .note(let text):
                    let note = try db.prepare("INSERT INTO inspirations(title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source,origin_kind,sort_order,lifecycle_token) VALUES(?,?,'idea','fallback',?,?,'manual','manual',(SELECT COALESCE(MAX(sort_order),0)+1 FROM inspirations),?)", operation: "assistant_note")
                    try note.bind(String(text.prefix(30)), at: 1); try note.bind(text, at: 2); try note.bind(Self.chatNow(), at: 3); try note.bind(Self.chatNow(), at: 4); try note.bind(turn.token, at: 5); try note.executeDone()
                    noteID = try db.lastInsertRowID()
                    // The insertion trigger assigns an identity; replace it inside this same
                    // transaction with the unique turn token so undo cannot target a reused row ID.
                    let identity = try db.prepare("UPDATE inspirations SET lifecycle_token=? WHERE id=?", operation: "assistant_note_identity")
                    try identity.bind(turn.token, at: 1); try identity.bind(noteID!, at: 2); try identity.executeDone()
                    row.answer = "已存进灵感。"
                }
                row.status = .complete; row.errorCode = nil
                let finish = try db.prepare("UPDATE chat_messages SET state='complete',content=?,error_code=NULL WHERE id=? AND attempt_token=?", operation: "assistant_routed_receipt")
                try finish.bind(row.answer, at: 1); try finish.bind(row.id, at: 2); try finish.bind(row.attempt, at: 3); try finish.executeDone()
                return .handled(row, noteID: noteID)
            }
        }
    }
    func undoAssistantNote(id: Int64, turn: String) async throws {
        try await performAsync { db in
            try db.transaction {
                let row = try db.prepare("DELETE FROM inspirations WHERE id=? AND lifecycle_token=? AND content_revision=0", operation: "undo_assistant_note")
                try row.bind(id, at: 1); try row.bind(turn, at: 2); try row.executeDone()
                guard try db.changesCount() == 1 else { throw AssistantError.stale }
                let receipt = try db.prepare("UPDATE chat_messages SET content='已撤销保存灵感。' WHERE turn_token=? AND role='assistant'", operation: "undo_note_receipt")
                try receipt.bind(turn, at: 1); try receipt.executeDone()
            }
        }
    }
}
