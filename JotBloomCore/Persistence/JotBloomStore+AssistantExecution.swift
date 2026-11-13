import Foundation

extension JotBloomStore {
    static func executionState(_ db: SQLiteConnection, id: String) throws -> AssistantExecutionState {
        let row = try db.prepare("SELECT state_json FROM assistant_task_runtime WHERE task_id=?", operation: "runtime_state")
        try row.bind(id, at: 1)
        return try row.stepRow() ? JSONDecoder().decode(AssistantExecutionState.self, from: Data(row.text(at: 0).utf8)) : .init()
    }
    static func saveExecutionState(_ db: SQLiteConnection, id: String, state: AssistantExecutionState) throws {
        let row = try db.prepare("INSERT INTO assistant_task_runtime(task_id,state_json) VALUES(?,?) ON CONFLICT(task_id) DO UPDATE SET state_json=excluded.state_json", operation: "save_runtime")
        try row.bind(id, at: 1); try row.bind(assistantJSON(state), at: 2); try row.executeDone()
    }
    func executionState(id: String) async throws -> AssistantExecutionState { try await performAsync { try Self.executionState($0, id: id) } }
    func saveExecutionState(id: String, state: AssistantExecutionState) async throws {
        try await performAsync { db in
            guard try Self.assistantTask(id, db: db)?.status == .running else { throw AssistantError.invalidTransition }
            try Self.saveExecutionState(db, id: id, state: state)
        }
    }
    public func executionSteps(id: String) async throws -> [AssistantExecutionStep] {
        try await performAsync { db in
            let row = try db.prepare("SELECT id,tool,args_json,state,COALESCE(result_text,''),undo_json,undone_at_ms FROM assistant_task_steps WHERE task_id=? ORDER BY step_index", operation: "execution_steps")
            try row.bind(id, at: 1); var values: [AssistantExecutionStep] = []
            while try row.stepRow() {
                guard let tool = AssistantToolName(rawValue: row.text(at: 1)) else { continue }
                let args = try JSONDecoder().decode([String: ToolValue].self, from: Data(row.text(at: 2).utf8))
                values.append(.init(id: row.int64(at: 0), action: .init(tool: tool, args: args), state: row.text(at: 3), result: row.text(at: 4), undo: row.optionalText(at: 5), undone: row.optionalText(at: 6) != nil))
            }
            return values
        }
    }
    func beginExecutionStep(id: String, action: AssistantStepAction, decision: String, userInitiated: Bool = false) async throws -> Int64 {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.scope != nil,
                      task.status == .running || (userInitiated && task.status.isTerminal && action.tool == .saveInspiration) else { throw AssistantError.invalidTransition }
                let row = try db.prepare("INSERT INTO assistant_task_steps(task_id,step_index,tool,args_json,decision,state,created_at_ms) VALUES(?,(SELECT COALESCE(MAX(step_index),0)+1 FROM assistant_task_steps WHERE task_id=?),?,?,?,'running',?)", operation: "begin_execution_step")
                try row.bind(id, at: 1); try row.bind(id, at: 2); try row.bind(action.tool.rawValue, at: 3); try row.bind(Self.assistantJSON(action.args), at: 4); try row.bind(decision, at: 5); try row.bind(Self.chatNow(), at: 6); try row.executeDone()
                return try db.lastInsertRowID()
            }
        }
    }
    static func finishExecutionStep(_ db: SQLiteConnection, taskID: String, stepID: Int64, result: String, failed: Bool = false, undo: String? = nil, progress: String) throws {
        let row = try db.prepare("UPDATE assistant_task_steps SET state=?,result_text=?,undo_json=? WHERE id=? AND task_id=? AND state='running'", operation: "finish_execution_step")
        try row.bind(failed ? "failed" : "done", at: 1); try row.bind(String(result.prefix(8000)), at: 2); try row.bind(undo, at: 3); try row.bind(stepID, at: 4); try row.bind(taskID, at: 5); try row.executeDone()
        guard try db.changesCount() == 1 else { throw AssistantError.invalidTransition }
        try appendAssistantEvent(db, taskID: taskID, kind: "step:\(stepID)", text: progress, time: chatNow())
        let touch = try db.prepare("UPDATE assistant_tasks SET updated_at_ms=? WHERE id=?", operation: "runtime_activity")
        try touch.bind(chatNow(), at: 1); try touch.bind(taskID, at: 2); try touch.executeDone()
    }
    func finishExecutionStep(id: String, stepID: Int64, result: String, failed: Bool = false, progress: String) async throws {
        try await performAsync { db in try db.transaction { try Self.finishExecutionStep(db, taskID: id, stepID: stepID, result: result, failed: failed, progress: progress) } }
    }
    public func executionQuestion(id: String) async throws -> AssistantRuntimeQuestion? {
        try await performAsync { db in
            let row = try db.prepare("SELECT payload_json FROM assistant_questions WHERE task_id=? AND kind IN ('runtimeClarify','scope','budget','stuck','overtime','approval','agentQuestion','codexResult','supervision') AND answered_at_ms IS NULL ORDER BY created_at_ms DESC LIMIT 1", operation: "runtime_question")
            try row.bind(id, at: 1)
            return try row.stepRow() ? JSONDecoder().decode(AssistantRuntimeQuestion.self, from: Data(row.text(at: 0).utf8)) : nil
        }
    }
    func waitForExecutionAnswer(id: String, question: AssistantRuntimeQuestion) async throws {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.scope != nil, [.running, .interrupted].contains(task.status) else { throw AssistantError.invalidTransition }
                let row = try db.prepare("INSERT INTO assistant_questions(id,task_id,kind,payload_json,created_at_ms) VALUES(?,?,?,?,?)", operation: "runtime_ask")
                try row.bind(question.id, at: 1); try row.bind(id, at: 2); try row.bind(question.kind, at: 3); try row.bind(Self.assistantJSON(question), at: 4); try row.bind(Self.chatNow(), at: 5); try row.executeDone()
                let update = try db.prepare("UPDATE assistant_tasks SET status='waitingUser',error_code=NULL,updated_at_ms=? WHERE id=?", operation: "runtime_wait")
                try update.bind(Self.chatNow(), at: 1); try update.bind(id, at: 2); try update.executeDone()
                try Self.appendAssistantEvent(db, taskID: id, kind: "waitingUser", text: question.text, time: Self.chatNow())
            }
        }
    }
    /// Called only by the user's answer button. Candidate titles never enter the model's answer text.
    func answerExecutionQuestion(id: String, questionID: String, allow: Bool, selected: Set<String>, answer: String) async throws {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.status == .waitingUser, var scope = task.scope else { throw AssistantError.invalidTransition }
                let row = try db.prepare("SELECT payload_json FROM assistant_questions WHERE id=? AND task_id=? AND answered_at_ms IS NULL", operation: "answer_runtime_question")
                try row.bind(questionID, at: 1); try row.bind(id, at: 2); guard try row.stepRow() else { throw AssistantError.stale }
                let question = try JSONDecoder().decode(AssistantRuntimeQuestion.self, from: Data(row.text(at: 0).utf8))
                var state = try Self.executionState(db, id: id)
                var reply = allow ? "用户已确认，按当前范围继续。" : "用户拒绝这项申请，用已有范围继续。"
                var status = TaskStatus.queued
                switch question.kind {
                case "scope":
                    let kind = question.scopeKind ?? ""
                    if allow {
                        if kind == "network" { scope.allowNetwork = true }
                        else if kind == "materials" {
                            let additions = question.candidates.filter { selected.contains($0.id) }
                            guard !additions.isEmpty else { throw AssistantError.empty }
                            state.declinedMaterials = (state.declinedMaterials ?? []).union(question.candidates.filter { !selected.contains($0.id) }.map(\.id)).subtracting(additions.map(\.id))
                            for item in additions where !scope.materials.contains(where: { $0.id == item.id }) { scope.materials.append(item); try Self.recordExecutionMaterial(db, id: id, material: item, selected: true, sent: false, source: "user") }
                            reply = "用户允许使用选中的 \(additions.count) 条资料；资料清单已更新。本次未选的资料不再申请，请用已选资料继续，资料不足时注明限制。"
                        } else if kind == "codex" { scope.allowCodex = true } else { throw AssistantError.invalidTransition }
                    } else { state.deniedScopes.insert(kind) }
                    if kind == "materials" { state.candidates.removeAll() }
                case "budget":
                    if allow { state.stepLimit += 20; state.tokenLimit += 300_000; state.lastFingerprint = ""; state.repeats = 0 }
                    else { status = .completed; reply = "你选择先到这里，已有结果保留。" }
                case "stuck", "overtime":
                    if allow { state.lastFingerprint = ""; state.repeats = 0; state.timeLimitSeconds = state.activeSeconds + 3600 }
                    else { status = .cancelled; reply = "你停止了任务，已有结果保留。" }
                case "codexResult":
                    if answer == "completed" { status = .completed; reply = "你确认任务已完成，已有文件保留。" }
                    else if !allow { status = .cancelled; reply = "你结束了任务，已有文件保留。" }
                    else { state.supplements.append("请继续检查 Codex 的实际结果，不能将未完成当作完成。") }
                case "runtimeClarify":
                    guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.empty }
                    reply = "用户补充：" + String(answer.prefix(8000)); state.supplements.append(reply)
                    if let thread = question.codexThreadID { state.codexUserAnswer = .init(threadID: thread, text: String(answer.prefix(8000))) }
                    state.userURLs += UserProvidedURLs.extract(answer).filter { !state.userURLs.contains($0) }
                    state.deniedScopes.removeAll(); state.declinedMaterials = nil
                case "supervision":
                    if !allow { status = .cancelled; reply = "你结束了任务，已有文件保留。" }
                    else {
                        reply = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "用户确认按原目标和权限范围继续，先检查偏离及已有结果。" : "用户补充方向（权限范围不变）：" + String(answer.prefix(8000))
                        state.supplements.append(reply); state.lastFingerprint = ""; state.repeats = 0
                    }
                default: throw AssistantError.invalidTransition
                }
                try Self.saveExecutionState(db, id: id, state: state)
                let update = try db.prepare("UPDATE assistant_tasks SET scope_json=?,allow_network=?,status=?,updated_at_ms=?,completed_at_ms=?,result_summary=CASE WHEN ? THEN ? ELSE result_summary END WHERE id=?", operation: "user_updates_scope")
                try update.bind(Self.assistantJSON(scope), at: 1); try update.bind(Int64(scope.allowNetwork ? 1 : 0), at: 2); try update.bind(status.rawValue, at: 3); try update.bind(Self.chatNow(), at: 4)
                try update.bindOptionalInteger(status.isTerminal ? Self.chatNow() : nil, at: 5); try update.bind(Int64(status.isTerminal ? 1 : 0), at: 6); try update.bind(reply, at: 7); try update.bind(id, at: 8); try update.executeDone()
                let answered = try db.prepare("UPDATE assistant_questions SET answer_json=?,answered_at_ms=? WHERE id=?", operation: "close_runtime_question")
                try answered.bind(Self.assistantJSON(["answer": reply]), at: 1); try answered.bind(Self.chatNow(), at: 2); try answered.bind(questionID, at: 3); try answered.executeDone()
                if let stepID = question.stepID { try Self.finishExecutionStep(db, taskID: id, stepID: stepID, result: reply, progress: reply) }
                else { try Self.appendAssistantEvent(db, taskID: id, kind: "userAnswered", text: reply, time: Self.chatNow()) }
                if status.isTerminal { try Self.cancelExecutionReminders(db, id: id) }
            }
        }
    }
    func finishExecution(id: String, summary: String, failed: Bool = false, code: String? = nil) async throws {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.status == .running else { throw AssistantError.invalidTransition }
                let row = try db.prepare("UPDATE assistant_tasks SET status=?,result_summary=?,error_code=?,updated_at_ms=?,completed_at_ms=? WHERE id=?", operation: "finish_runtime")
                try row.bind(failed ? "failed" : "completed", at: 1); try row.bind(summary, at: 2); try row.bind(code, at: 3); try row.bind(Self.chatNow(), at: 4); try row.bind(Self.chatNow(), at: 5); try row.bind(id, at: 6); try row.executeDone()
                try Self.cancelExecutionReminders(db, id: id)
                try Self.appendAssistantEvent(db, taskID: id, kind: failed ? "failed" : "completed", text: summary, time: Self.chatNow())
            }
        }
    }
    static func cancelExecutionReminders(_ db: SQLiteConnection, id: String) throws {
        let row = try db.prepare("UPDATE assistant_reminders SET state='cancelled' WHERE task_id=? AND state='pending'", operation: "cancel_runtime_reminders")
        try row.bind(id, at: 1); try row.executeDone()
    }
    public func executionMaterialUsage(id: String) async throws -> [AssistantMaterialUsage] {
        try await performAsync { db in
            let row = try db.prepare("SELECT kind,ref_id,title_snapshot,selected,sent_at_ms FROM assistant_materials WHERE task_id=? ORDER BY sent_at_ms DESC, rowid", operation: "execution_material_usage")
            try row.bind(id, at: 1); var result: [AssistantMaterialUsage] = []; var seen: Set<String> = []
            while try row.stepRow() {
                guard let kind = AssistantMaterialKind(rawValue: row.text(at: 0)) else { continue }
                let material = AssistantAttachment(kind: kind, reference: row.text(at: 1), title: row.text(at: 2))
                if seen.insert(material.id).inserted { result.append(.init(attachment: material, selected: row.int64(at: 3) == 1, sent: row.optionalText(at: 4) != nil)) }
            }
            return result
        }
    }
    static func recordExecutionMaterial(_ db: SQLiteConnection, id: String, material: AssistantAttachment, selected: Bool, sent: Bool, source: String) throws {
        let existing = try db.prepare("SELECT id FROM assistant_materials WHERE task_id=? AND kind=? AND ref_id=? LIMIT 1", operation: "existing_runtime_material")
        try existing.bind(id, at: 1); try existing.bind(material.kind.rawValue, at: 2); try existing.bind(material.reference, at: 3)
        if try existing.stepRow() {
            let row = try db.prepare("UPDATE assistant_materials SET selected=MAX(selected,?),sent_at_ms=CASE WHEN ? THEN ? ELSE sent_at_ms END WHERE id=?", operation: "mark_runtime_material")
            try row.bind(Int64(selected ? 1 : 0), at: 1); try row.bind(Int64(sent ? 1 : 0), at: 2); try row.bind(chatNow(), at: 3); try row.bind(existing.text(at: 0), at: 4); try row.executeDone()
        } else {
            let row = try db.prepare("INSERT INTO assistant_materials(id,task_id,kind,ref_id,source,title_snapshot,selected,sent_at_ms) VALUES(?,?,?,?,?,?,?,?)", operation: "record_runtime_material")
            try row.bind(UUID().uuidString, at: 1); try row.bind(id, at: 2); try row.bind(material.kind.rawValue, at: 3); try row.bind(material.reference, at: 4); try row.bind(source, at: 5); try row.bind(material.title, at: 6); try row.bind(Int64(selected ? 1 : 0), at: 7); try row.bindOptionalInteger(sent ? chatNow() : nil, at: 8); try row.executeDone()
        }
    }
    func recordExecutionMaterial(id: String, material: AssistantAttachment, selected: Bool, sent: Bool) async throws {
        try await performAsync { try Self.recordExecutionMaterial($0, id: id, material: material, selected: selected, sent: sent, source: selected ? "user" : "auto") }
    }
    func executionMaterialText(_ material: AssistantAttachment) async throws -> String {
        try await performAsync { db in
            switch material.kind {
            case .inspiration, .prompt:
                let sql = material.kind == .inspiration ? "SELECT body FROM inspirations WHERE id=?" : "SELECT content FROM prompts WHERE id=?"
                let row = try db.prepare(sql, operation: "read_runtime_material"); try row.bind(material.reference, at: 1)
                guard try row.stepRow() else { throw ExecutionError.unreadable("这条资料已删除，可以用其他资料继续。") }; return row.text(at: 0)
            case .chat:
                let row = try db.prepare("SELECT s.token,u.id FROM chat_messages u JOIN chat_sessions s ON s.id=u.session_id WHERE u.turn_token=? AND u.role='user'", operation: "runtime_chat_reference")
                try row.bind(material.reference, at: 1); guard try row.stepRow() else { throw ExecutionError.unreadable("原对话已删除。") }
                let turns = try db.prepare("SELECT u.content,a.content FROM chat_messages u JOIN chat_messages a ON u.turn_token=a.turn_token AND u.session_id=a.session_id JOIN chat_sessions s ON s.id=u.session_id WHERE s.token=? AND u.role='user' AND a.role='assistant' AND a.state='complete' AND u.id<=? ORDER BY u.id DESC LIMIT 3", operation: "read_selected_chat")
                try turns.bind(row.text(at: 0), at: 1); try turns.bind(row.int64(at: 1), at: 2); var values: [String] = []
                while try turns.stepRow() { values.append("用户：" + turns.text(at: 0) + "\n助手：" + turns.text(at: 1)) }; return values.reversed().joined(separator: "\n")
            case .file: throw ExecutionError.denied("文件请使用读文件工具。")
            }
        }
    }
}
