import Foundation

extension JotBloomStore {
    static func assistantJSON<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }

    func beginAssistantUnderstanding(id: String, answer: [String: String]?, adjustment: String?) async throws {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.scope == nil,
                      [.received, .needsInfo, .planReady, .failed, .interrupted, .waitingUser].contains(task.status) else { throw AssistantError.invalidTransition }
                let event: TaskTransitionEvent
                switch task.status {
                case .received: event = .beginUnderstanding
                case .needsInfo: event = .userAnswered
                case .planReady: event = .adjustPlan
                case .waitingUser:
                    guard task.errorCode == "modelNotConfigured" else { throw AssistantError.invalidTransition }
                    event = .configurationReady
                case .failed:
                    guard task.errorCode == "understandingInvalid" else { throw AssistantError.invalidTransition }
                    event = .retryUnderstanding
                case .interrupted: event = .retryUnderstanding
                default: throw AssistantError.invalidTransition
                }
                _ = try TaskTransition.next(from: task.status, event: event)
                if task.status == .needsInfo {
                    guard let questions = task.brief?.questions, let answer,
                          questions.allSatisfy({ !(answer[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw AssistantError.empty }
                    let row = try db.prepare("UPDATE assistant_questions SET answer_json=?,answered_at_ms=? WHERE task_id=? AND kind='clarify' AND answered_at_ms IS NULL", operation: "answer_assistant_questions")
                    try row.bind(Self.assistantJSON(answer), at: 1); try row.bind(Self.chatNow(), at: 2); try row.bind(id, at: 3); try row.executeDone()
                }
                if let adjustment, !adjustment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let row = try db.prepare("INSERT INTO assistant_questions(id,task_id,kind,payload_json,answer_json,created_at_ms,answered_at_ms) VALUES(?,?,'adjust','{}',?,?,?)", operation: "adjust_assistant_plan")
                    try row.bind(UUID().uuidString, at: 1); try row.bind(id, at: 2); try row.bind(Self.assistantJSON(["调整": adjustment]), at: 3)
                    try row.bind(Self.chatNow(), at: 4); try row.bind(Self.chatNow(), at: 5); try row.executeDone()
                }
                let row = try db.prepare("UPDATE assistant_tasks SET status='understanding',error_code=NULL,completed_at_ms=NULL,updated_at_ms=? WHERE id=?", operation: "begin_understanding")
                try row.bind(Self.chatNow(), at: 1); try row.bind(id, at: 2); try row.executeDone()
                try Self.appendAssistantEvent(db, taskID: id, kind: "understanding", text: "正在理解，只发送交办文字、文件名和相关的最近 3 轮对话。", time: Self.chatNow())
            }
        }
    }
    func assistantUnderstandingInput(id: String, now: Date, timeZone: TimeZone) async throws -> UnderstandingInput {
        try await performAsync { db in
            guard let task = try Self.assistantTask(id, db: db) else { throw AssistantError.missing }
            let files = try db.prepare("SELECT title_snapshot FROM assistant_materials WHERE task_id=? AND kind='file'", operation: "understanding_filenames")
            try files.bind(id, at: 1); var filenames: [String] = []; while try files.stepRow() { filenames.append(files.text(at: 0)) }
            let answers = try db.prepare("SELECT payload_json,answer_json,kind FROM assistant_questions WHERE task_id=? AND answered_at_ms IS NOT NULL AND kind IN ('clarify','adjust') ORDER BY created_at_ms", operation: "understanding_answers")
            try answers.bind(id, at: 1); var responses: [String] = []; var rounds = 0
            while try answers.stepRow() { responses.append(answers.text(at: 0) + "\n" + answers.text(at: 1)); if answers.text(at: 2) == "clarify" { rounds += 1 } }
            var history: [ChatTurn] = []
            if let session = task.chatSession, let turn = task.chatTurn {
                let rows = try db.prepare("""
                    SELECT a.id,a.turn_token,u.content,a.content,a.created_at_utc_ms FROM chat_messages a
                    JOIN chat_sessions s ON s.id=a.session_id JOIN chat_messages u ON u.turn_token=a.turn_token AND u.role='user' AND u.session_id=a.session_id
                    WHERE s.token=? AND a.role='assistant' AND a.state='complete'
                    AND a.id <= COALESCE((SELECT id FROM chat_messages WHERE turn_token=? AND role='assistant'),0)
                    ORDER BY a.id DESC LIMIT 3
                    """, operation: "assistant_three_turn_context")
                try rows.bind(session, at: 1); try rows.bind(turn, at: 2)
                while try rows.stepRow() { history.append(.init(id: rows.int64(at: 0), session: session, token: rows.text(at: 1), attempt: "", user: rows.text(at: 2), answer: rows.text(at: 3), timestamp: rows.int64(at: 4), status: .complete)) }
            }
            return .init(text: task.rawInput, filenames: filenames, history: history.reversed(), answers: responses, now: now, timeZone: timeZone, questionRounds: rounds)
        }
    }
    /// Local search returns titles/references to the UI only. No material content is sent during planning.
    public func assistantMaterialCandidates(keywords: [String], all: Bool = false) async throws -> [AssistantAttachment] {
        try await performAsync { db in
            var ranked: [(AssistantAttachment, Int)] = []
            for (table, body, kind) in [("inspirations", "body", AssistantMaterialKind.inspiration), ("prompts", "content", .prompt)] {
                let rows = try db.prepare("SELECT id,title,\(body) FROM \(table) ORDER BY created_at_utc_ms DESC", operation: "assistant_local_material_search")
                while try rows.stepRow() {
                    let text = rows.text(at: 1) + "\n" + rows.text(at: 2)
                    let score = keywords.filter { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }.count
                    if all || score > 0 { ranked.append((.init(kind: kind, reference: String(rows.int64(at: 0)), title: rows.text(at: 1)), score)) }
                }
            }
            return ranked.enumerated().sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 > $1.element.1 }
                .prefix(all ? 200 : 8).map { $0.element.0 }
        }
    }
    func assistantCheckedMaterials(_ values: [AssistantMaterial]) async throws -> [AssistantMaterial] {
        try await performAsync { db in
            try values.map { value in
                var result = value; let item = value.attachment
                switch item.kind {
                case .file: result.available = FileManager.default.fileExists(atPath: item.reference)
                case .inspiration, .prompt:
                    let row = try db.prepare("SELECT id FROM \(item.kind == .inspiration ? "inspirations" : "prompts") WHERE id=?", operation: "validate_assistant_material")
                    try row.bind(item.reference, at: 1); result.available = try row.stepRow()
                case .chat:
                    let row = try db.prepare("SELECT id FROM chat_messages WHERE turn_token=? LIMIT 1", operation: "validate_assistant_chat")
                    try row.bind(item.reference, at: 1); result.available = try row.stepRow()
                }
                if !result.available { result.selected = false }; return result
            }
        }
    }
    func saveAssistantUnderstanding(id: String, brief: TaskBrief, plan: AssistantPlan, directReminder: Bool) async throws {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.status == .understanding else { throw AssistantError.invalidTransition }
                var plan = plan
                if task.plan == nil {
                    let existing = try db.prepare("SELECT plan_json FROM assistant_tasks WHERE id!=? AND plan_json IS NOT NULL", operation: "reserve_assistant_output")
                    try existing.bind(id, at: 1); var reserved: [String] = []
                    while try existing.stepRow() {
                        reserved.append(try JSONDecoder().decode(AssistantPlan.self, from: Data(existing.text(at: 0).utf8)).outputDirectory)
                    }
                    plan.outputDirectory = AssistantOutputLocation.suggested(title: brief.title, now: Date(), reserved: reserved, parentPath: URL(fileURLWithPath: plan.outputDirectory).deletingLastPathComponent().path)
                } else if let previous = task.plan { plan.outputDirectory = previous.outputDirectory }
                let status = try TaskTransition.next(from: task.status, event: !brief.questions.isEmpty ? .understoodWithQuestions : directReminder ? .understoodReminder : .understoodWithPlan)
                let row = try db.prepare("UPDATE assistant_tasks SET title=?,brief_json=?,plan_json=?,status=?,due_at_ms=?,updated_at_ms=? WHERE id=?", operation: "save_assistant_understanding")
                try row.bind(brief.title, at: 1); try row.bind(Self.assistantJSON(brief), at: 2); try row.bind(Self.assistantJSON(plan), at: 3)
                try row.bind(status.rawValue, at: 4); if let due = plan.dueAt { try row.bind(due, at: 5) } else { try row.bind(nil as String?, at: 5) }; try row.bind(Self.chatNow(), at: 6); try row.bind(id, at: 7); try row.executeDone()
                if status == .needsInfo {
                    let q = try db.prepare("INSERT INTO assistant_questions(id,task_id,kind,payload_json,created_at_ms) VALUES(?,?,'clarify',?,?)", operation: "save_assistant_questions")
                    try q.bind(UUID().uuidString, at: 1); try q.bind(id, at: 2); try q.bind(Self.assistantJSON(brief.questions), at: 3); try q.bind(Self.chatNow(), at: 4); try q.executeDone()
                }
                try Self.replaceAssistantMaterials(db, id: id, values: plan.materials)
                if status == .scheduled { try Self.insertAssistantReminders(db, id: id, times: plan.reminders, origins: plan.reminderOrigins ?? [:]) }
                try Self.appendAssistantEvent(db, taskID: id, kind: status.rawValue,
                    text: status == .scheduled ? "已设好：" + plan.reminders.map(AssistantDates.text).joined(separator: "、") : status == .needsInfo ? "有几件事需要你补充。" : "计划已准备好，等你确认范围。", time: Self.chatNow())
            }
        }
    }
    func failAssistantUnderstanding(id: String, configuration: Bool, message: String) async throws {
        try await performAsync { db in
            guard let task = try Self.assistantTask(id, db: db), [.understanding, .received].contains(task.status) else { return }
            let row = try db.prepare("UPDATE assistant_tasks SET status=?,error_code=?,updated_at_ms=? WHERE id=?", operation: "fail_understanding")
            try row.bind(configuration ? "waitingUser" : "failed", at: 1); try row.bind(configuration ? "modelNotConfigured" : "understandingInvalid", at: 2)
            try row.bind(Self.chatNow(), at: 3); try row.bind(id, at: 4); try row.executeDone()
            try Self.appendAssistantEvent(db, taskID: id, kind: "understandingError", text: message, time: Self.chatNow())
        }
    }
    func saveAssistantPlanDraft(id: String, plan: AssistantPlan) async throws {
        try await performAsync { db in
            let row = try db.prepare("UPDATE assistant_tasks SET plan_json=? WHERE id=? AND status='planReady' AND scope_json IS NULL", operation: "assistant_plan_draft")
            try row.bind(Self.assistantJSON(plan), at: 1); try row.bind(id, at: 2); try row.executeDone()
        }
    }
    func refreshAssistantPlan(id: String, plan: AssistantPlan) async throws {
        try await performAsync { db in
            let row = try db.prepare("UPDATE assistant_tasks SET plan_json=?,updated_at_ms=? WHERE id=? AND status='planReady'", operation: "refresh_plan_materials")
            try row.bind(Self.assistantJSON(plan), at: 1); try row.bind(Self.chatNow(), at: 2); try row.bind(id, at: 3); try row.executeDone()
        }
    }
    func confirmAssistantPlan(id: String, plan: AssistantPlan, now: Int64) async throws {
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.status == .planReady else { throw AssistantError.invalidTransition }
                guard !plan.brief.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !plan.outputDirectory.isEmpty else { throw AssistantError.empty }
                let occupied = try db.prepare("SELECT id FROM assistant_tasks WHERE id!=? AND output_directory=? LIMIT 1", operation: "check_unique_task_output")
                try occupied.bind(id, at: 1); try occupied.bind(plan.outputDirectory, at: 2)
                guard try !occupied.stepRow() else { throw AssistantError.stale }
                let answers = try db.prepare("SELECT payload_json,answer_json FROM assistant_questions WHERE task_id=? AND answered_at_ms IS NOT NULL AND kind IN ('clarify','adjust') ORDER BY created_at_ms", operation: "freeze_confirmed_answers")
                try answers.bind(id, at: 1); var confirmedAnswers: [String] = []
                while try answers.stepRow() { confirmedAnswers.append(String((answers.text(at: 0) + "\n" + answers.text(at: 1)).prefix(8000))) }
                let scope = TaskScope(goal: plan.brief.summary, doneCriteria: plan.brief.doneCriteria,
                    materials: plan.materials.filter { $0.selected && $0.available }.map(\.attachment), autoFind: plan.autoFind,
                    allowCodex: plan.allowCodex, allowNetwork: plan.allowNetwork, confirmedAnswers: confirmedAnswers, permissionMode: plan.permissionMode, workingDirectory: plan.allowCodex ? plan.workingDirectory : nil, outputDirectory: plan.outputDirectory)
                let status = try TaskTransition.next(from: task.status, event: task.brief?.needsWork == false ? .userConfirmedReminder : .userConfirmedWork).rawValue
                let row = try db.prepare("UPDATE assistant_tasks SET scope_json=?,plan_json=?,status=?,due_at_ms=?,output_directory=?,allow_network=?,agent=?,updated_at_ms=? WHERE id=?", operation: "confirm_assistant_scope")
                try row.bind(Self.assistantJSON(scope), at: 1); try row.bind(Self.assistantJSON(plan), at: 2); try row.bind(status, at: 3)
                if let due = plan.dueAt { try row.bind(due, at: 4) } else { try row.bind(nil as String?, at: 4) }; try row.bind(plan.outputDirectory, at: 5); try row.bind(Int64(plan.allowNetwork ? 1 : 0), at: 6)
                try row.bind(plan.allowCodex ? "codex" : nil, at: 7); try row.bind(now, at: 8); try row.bind(id, at: 9); try row.executeDone()
                try Self.replaceAssistantMaterials(db, id: id, values: plan.materials)
                try Self.insertAssistantReminders(db, id: id, times: plan.reminders.filter { $0 > now }, origins: plan.reminderOrigins ?? [:])
                try Self.appendAssistantEvent(db, taskID: id, kind: "scopeConfirmed", text: "你确认了目标和范围，资料尚未发送。", time: now)
            }
        }
    }
    static func replaceAssistantMaterials(_ db: SQLiteConnection, id: String, values: [AssistantMaterial]) throws {
        let delete = try db.prepare("DELETE FROM assistant_materials WHERE task_id=? AND sent_at_ms IS NULL", operation: "replace_assistant_materials")
        try delete.bind(id, at: 1); try delete.executeDone()
        var seen: Set<String> = []
        for value in values where seen.insert(value.id).inserted {
            let row = try db.prepare("INSERT INTO assistant_materials(id,task_id,kind,ref_id,source,title_snapshot,selected) VALUES(?,?,?,?,'plan',?,?)", operation: "save_plan_material")
            try row.bind(UUID().uuidString, at: 1); try row.bind(id, at: 2); try row.bind(value.attachment.kind.rawValue, at: 3)
            try row.bind(value.attachment.reference, at: 4); try row.bind(value.attachment.title, at: 5); try row.bind(Int64(value.selected && value.available ? 1 : 0), at: 6); try row.executeDone()
        }
    }
    static func insertAssistantReminders(_ db: SQLiteConnection, id: String, times: [Int64], origins: [String: AssistantReminderOrigin] = [:]) throws {
        for time in Set(times) {
            let row = try db.prepare("INSERT INTO assistant_reminders(id,task_id,fire_at_ms,state,origin) VALUES(?,?,?,'pending',?)", operation: "schedule_assistant_reminder")
            try row.bind(UUID().uuidString, at: 1); try row.bind(id, at: 2); try row.bind(time, at: 3); try row.bind((origins[String(time)] ?? .auto).rawValue, at: 4); try row.executeDone()
        }
    }
}
