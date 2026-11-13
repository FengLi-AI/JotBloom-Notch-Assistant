import Foundation

struct AssistantUndo: Codable {
    var kind: String
    var reference: String
    var identity: String?
    var previousTime: Int64?
    var appliedTime: Int64?
    var previousOrigin: AssistantReminderOrigin? = nil
}
extension JotBloomStore {
    /// The mutation and its undo record commit together. A crashed step can never
    /// have an unrecorded note/reminder that a resume would blindly duplicate.
    func executeRecordedEffect(id: String, stepID: Int64, action: AssistantStepAction, userInitiated: Bool = false) async throws -> String {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.scope != nil,
                      task.status == .running || (userInitiated && task.status.isTerminal && action.tool == .saveInspiration) else { throw AssistantError.invalidTransition }
                let result: String, undo: AssistantUndo, progress: String
                switch action.tool {
                case .saveInspiration:
                    let text = action.args["content"]!.text!, identity = UUID().uuidString
                    let row = try db.prepare("INSERT INTO inspirations(title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source,origin_kind,sort_order) VALUES(?,?,'idea','fallback',?,?,'manual','manual',(SELECT COALESCE(MAX(sort_order),0)+1 FROM inspirations))", operation: "runtime_save_inspiration")
                    try row.bind(String(text.prefix(30)), at: 1); try row.bind(text, at: 2); try row.bind(Self.chatNow(), at: 3); try row.bind(Self.chatNow(), at: 4); try row.executeDone()
                    let noteID = try db.lastInsertRowID()
                    let token = try db.prepare("UPDATE inspirations SET lifecycle_token=? WHERE id=?", operation: "runtime_note_identity")
                    try token.bind(identity, at: 1); try token.bind(noteID, at: 2); try token.executeDone()
                    undo = .init(kind: "inspiration", reference: String(noteID), identity: identity)
                    result = "已保存一条新灵感，id=\(noteID)。"; progress = "存成了一条新灵感，可撤销。"
                case .setReminder:
                    guard let time = action.args["time"]?.text.flatMap({ AssistantDates.parse($0, timeZone: .current) }), time > Self.chatNow() else { throw ExecutionError.denied("提醒时间已经过去，请选择未来的具体时间。") }
                    let reminderID = action.args["id"]?.text ?? UUID().uuidString
                    var previous: Int64?
                    var previousOrigin: AssistantReminderOrigin?
                    if action.args["id"] != nil {
                        let current = try db.prepare("SELECT fire_at_ms,origin FROM assistant_reminders WHERE id=? AND task_id=? AND state='pending'", operation: "runtime_reminder_before")
                        try current.bind(reminderID, at: 1); try current.bind(id, at: 2)
                        guard try current.stepRow() else { throw ExecutionError.denied("只能修改本任务尚未触发的提醒。") }; previous = current.int64(at: 0)
                        previousOrigin = AssistantReminderOrigin(rawValue: current.text(at: 1)) ?? .auto
                        let update = try db.prepare("UPDATE assistant_reminders SET fire_at_ms=?,origin='agent' WHERE id=? AND task_id=?", operation: "runtime_reminder_change")
                        try update.bind(time, at: 1); try update.bind(reminderID, at: 2); try update.bind(id, at: 3); try update.executeDone()
                    } else {
                        let insert = try db.prepare("INSERT INTO assistant_reminders(id,task_id,fire_at_ms,state,origin) VALUES(?,?,?,'pending','agent')", operation: "runtime_reminder_new")
                        try insert.bind(reminderID, at: 1); try insert.bind(id, at: 2); try insert.bind(time, at: 3); try insert.executeDone()
                    }
                    undo = .init(kind: "reminder", reference: reminderID, previousTime: previous, appliedTime: time, previousOrigin: previousOrigin)
                    result = "提醒已保存，id=\(reminderID)，时间=" + AssistantDates.text(time)
                    progress = (previous == nil ? "加了一个提醒：" : "修改了提醒：") + AssistantDates.text(time) + "，可撤销。"
                default: throw ExecutionError.denied("该工具没有可撤销的数据操作。")
                }
                try Self.finishExecutionStep(db, taskID: id, stepID: stepID, result: result, undo: Self.assistantJSON(undo), progress: progress)
                return result
            }
        }
    }
    public func undoExecutionEffect(id: String, stepID: Int64) async throws {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db) else { throw AssistantError.missing }
                let row = try db.prepare("SELECT undo_json,args_json FROM assistant_task_steps WHERE task_id=? AND id=? AND undone_at_ms IS NULL AND undo_json IS NOT NULL AND state='done'", operation: "read_runtime_undo")
                try row.bind(id, at: 1); try row.bind(stepID, at: 2); guard try row.stepRow() else { throw AssistantError.stale }
                let undo = try JSONDecoder().decode(AssistantUndo.self, from: Data(row.text(at: 0).utf8))
                switch undo.kind {
                case "inspiration":
                    let original = try JSONDecoder().decode([String: ToolValue].self, from: Data(row.text(at: 1).utf8))["content"]?.text
                    let remove = try db.prepare("DELETE FROM inspirations WHERE id=? AND lifecycle_token=? AND content_revision=0 AND title_source!='user' AND category_source!='user' AND body=?", operation: "undo_runtime_note")
                    try remove.bind(undo.reference, at: 1); try remove.bind(undo.identity, at: 2); try remove.bind(original, at: 3); try remove.executeDone()
                    guard try db.changesCount() == 1 else { throw ExecutionError.denied("灵感已被修改或删除，已保留你的修改，不能自动撤销。") }
                case "reminder":
                    let time = undo.previousTime
                    let state = !task.status.isTerminal && (time ?? 0) > Self.chatNow() ? "pending" : "cancelled"
                    let update = try db.prepare("UPDATE assistant_reminders SET state=?,fire_at_ms=COALESCE(?,fire_at_ms),origin=? WHERE id=? AND task_id=? AND fire_at_ms=? AND state IN ('pending','cancelled')", operation: "undo_runtime_reminder")
                    try update.bind(state, at: 1); try update.bindOptionalInteger(time, at: 2); try update.bind((undo.previousOrigin ?? .auto).rawValue, at: 3); try update.bind(undo.reference, at: 4); try update.bind(id, at: 5); try update.bindOptionalInteger(undo.appliedTime, at: 6); try update.executeDone()
                    guard try db.changesCount() == 1 else { throw ExecutionError.denied("提醒已经触发或再次修改，不能覆盖之后的操作。") }
                default: throw AssistantError.invalidTransition
                }
                let done = try db.prepare("UPDATE assistant_task_steps SET undone_at_ms=? WHERE id=?", operation: "mark_runtime_undone")
                try done.bind(Self.chatNow(), at: 1); try done.bind(stepID, at: 2); try done.executeDone()
                try Self.appendAssistantEvent(db, taskID: id, kind: "undone", text: "已撤销这次" + (undo.kind == "inspiration" ? "新增灵感。" : "提醒修改。"), time: Self.chatNow())
                let touch = try db.prepare("UPDATE assistant_tasks SET updated_at_ms=? WHERE id=?", operation: "undo_task_touch")
                try touch.bind(Self.chatNow(), at: 1); try touch.bind(id, at: 2); try touch.executeDone()
            }
        }
    }
    func resumeExecution(id: String) async throws {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.status == .interrupted, task.scope != nil else { throw AssistantError.invalidTransition }
                let row = try db.prepare("UPDATE assistant_tasks SET status='queued',error_code=NULL,updated_at_ms=? WHERE id=?", operation: "resume_runtime")
                try row.bind(Self.chatNow(), at: 1); try row.bind(id, at: 2); try row.executeDone()
                let unknown = try db.prepare("UPDATE assistant_task_steps SET state='unknown' WHERE task_id=? AND state='running'", operation: "mark_unknown_steps")
                try unknown.bind(id, at: 1); try unknown.executeDone()
                try Self.appendAssistantEvent(db, taskID: id, kind: "resumed", text: "从保留的进度继续，结果不明的操作会先检查。", time: Self.chatNow())
            }
        }
    }
    func supplementExecution(id: String, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.empty }
        try await performAsync { db in
            guard let task = try Self.assistantTask(id, db: db), task.scope != nil, !task.status.isTerminal else { throw AssistantError.invalidTransition }
            var state = try Self.executionState(db, id: id)
            state.supplements.append(String(text.prefix(8000))); state.deniedScopes.removeAll(); state.declinedMaterials = nil
            state.userURLs += UserProvidedURLs.extract(text).filter { !state.userURLs.contains($0) }
            try Self.saveExecutionState(db, id: id, state: state)
            try Self.appendAssistantEvent(db, taskID: id, kind: "supplement", text: "你补充了要求，下次执行会参考。", time: Self.chatNow())
        }
    }
}

extension SQLiteStatement {
    func bindOptionalInteger(_ value: Int64?, at index: Int32) throws {
        if let value { try bind(value, at: index) } else { try bind(nil as String?, at: index) }
    }
}
