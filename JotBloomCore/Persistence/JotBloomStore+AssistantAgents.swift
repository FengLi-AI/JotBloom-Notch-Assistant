import Foundation

extension JotBloomStore {
    func failAgentExecution(id: String, message: String) async throws {
        try await performAsync { db in
            try db.transaction {
                let row = try db.prepare("UPDATE assistant_tasks SET status='failed',result_summary=?,error_code='agentFailed',updated_at_ms=?,completed_at_ms=? WHERE id=? AND status IN ('running','waitingUser','queued','interrupted')", operation: "fail_agent_task")
                try row.bind(message, at: 1); try row.bind(Self.chatNow(), at: 2); try row.bind(Self.chatNow(), at: 3); try row.bind(id, at: 4); try row.executeDone()
                try Self.cancelExecutionReminders(db, id: id)
                try Self.appendAssistantEvent(db, taskID: id, kind: "failed", text: message, time: Self.chatNow())
            }
        }
    }
    func accountAgentTime(id: String, seconds: Double) async throws {
        try await performAsync { db in
            guard try Self.assistantTask(id, db: db) != nil else { return }
            var state = try Self.executionState(db, id: id); state.activeSeconds += max(0, seconds)
            try Self.saveExecutionState(db, id: id, state: state)
        }
    }
    public func agentSession(id: String) async throws -> AgentSession {
        try await performAsync { db in
            let row = try db.prepare("SELECT state_json FROM assistant_agent_sessions WHERE task_id=?", operation: "agent_session")
            try row.bind(id, at: 1)
            return try row.stepRow() ? JSONDecoder().decode(AgentSession.self, from: Data(row.text(at: 0).utf8)) : .init()
        }
    }
    func saveAgentSession(id: String, session: AgentSession) async throws {
        try await performAsync { db in
            try db.transaction {
                let row = try db.prepare("INSERT INTO assistant_agent_sessions(task_id,state_json) VALUES(?,?) ON CONFLICT(task_id) DO UPDATE SET state_json=excluded.state_json", operation: "save_agent_session")
                try row.bind(id, at: 1); try row.bind(Self.assistantJSON(session), at: 2); try row.executeDone()
                let task = try db.prepare("UPDATE assistant_tasks SET agent='codex',agent_thread_id=?,agent_turn_id=? WHERE id=?", operation: "agent_task_reference")
                try task.bind(session.threadID, at: 1); try task.bind(session.turnID, at: 2); try task.bind(id, at: 3); try task.executeDone()
                if let thread = session.threadID {
                    let owned = try db.prepare("INSERT OR IGNORE INTO assistant_owned_threads(thread_id) VALUES(?)", operation: "own_agent_thread")
                    try owned.bind(thread, at: 1); try owned.executeDone()
                }
            }
        }
    }
    public func ownedAgentThreads() async throws -> Set<String> {
        try await performAsync { db in
            let row = try db.prepare("SELECT thread_id FROM assistant_owned_threads", operation: "owned_agent_threads"); var values: Set<String> = []
            while try row.stepRow() { values.insert(row.text(at: 0)) }; return values
        }
    }
    func agentProgress(id: String, text: String, kind: String = "agent") async throws {
        try await performAsync { db in
            try Self.appendAssistantEvent(db, taskID: id, kind: kind, text: String(text.prefix(500)), time: Self.chatNow())
            let row = try db.prepare("UPDATE assistant_tasks SET updated_at_ms=? WHERE id=?", operation: "agent_activity")
            try row.bind(Self.chatNow(), at: 1); try row.bind(id, at: 2); try row.executeDone()
        }
    }
    func reserveSupervisionBudget(id: String, estimatedTokens: Int) async throws -> Bool {
        try await performAsync { db in
            guard try Self.assistantTask(id, db: db)?.status == .running else { return false }
            var state = try Self.executionState(db, id: id)
            guard state.calls < state.stepLimit, state.estimatedTokens + estimatedTokens <= state.tokenLimit else { return false }
            state.calls += 1; state.estimatedTokens += estimatedTokens
            try Self.saveExecutionState(db, id: id, state: state); return true
        }
    }
    func resolveAgentQuestion(id: String, question: String, answer: String, queue: Bool, payload: ToolValue? = nil) async throws {
        try await performAsync { db in
            try db.transaction {
                let row = try db.prepare("UPDATE assistant_questions SET answer_json=?,answered_at_ms=? WHERE id=? AND task_id=? AND answered_at_ms IS NULL", operation: "resolve_agent_question")
                try row.bind(try payload?.json ?? Self.assistantJSON(["answer": answer]), at: 1); try row.bind(Self.chatNow(), at: 2); try row.bind(question, at: 3); try row.bind(id, at: 4); try row.executeDone()
                guard try db.changesCount() == 1 else { throw AssistantError.stale }
                let update = try db.prepare("UPDATE assistant_tasks SET status=CASE WHEN ? THEN 'queued' ELSE status END,updated_at_ms=? WHERE id=? AND status='waitingUser'", operation: "queue_agent_answer")
                try update.bind(Int64(queue ? 1 : 0), at: 1); try update.bind(Self.chatNow(), at: 2); try update.bind(id, at: 3); try update.executeDone()
                try Self.appendAssistantEvent(db, taskID: id, kind: "agentAnswer", text: answer, time: Self.chatNow())
            }
        }
    }
    func reserveAgentAnswerBudget(id: String, questionID: String, estimatedTokens: Int) async throws -> Bool {
        try await performAsync { db in
            guard try Self.assistantTask(id, db: db)?.status == .waitingUser else { return false }
            let pending = try db.prepare("SELECT id FROM assistant_questions WHERE id=? AND task_id=? AND kind='agentQuestion' AND answered_at_ms IS NULL", operation: "reserve_agent_answer")
            try pending.bind(questionID, at: 1); try pending.bind(id, at: 2)
            guard try pending.stepRow() else { return false }
            var state = try Self.executionState(db, id: id)
            guard state.calls < state.stepLimit, state.estimatedTokens + estimatedTokens <= state.tokenLimit,
                  state.activeSeconds < state.timeLimitSeconds else { return false }
            state.calls += 1; state.estimatedTokens += estimatedTokens
            try Self.saveExecutionState(db, id: id, state: state); return true
        }
    }
    func recoverAgentSessions() async throws {
        let tasks = try await assistantTasks()
        for task in tasks {
            var session = try await agentSession(id: task.id)
            guard session.active || session.pending != nil else { continue }
            if let pending = session.pending { try? await resolveAgentQuestion(id: task.id, question: pending.id, answer: "连接已结束，旧批准已失效，未发送批准。", queue: false) }
            session.pending = nil; session.response = nil; session.active = false; session.needsResume = true
            try await saveAgentSession(id: task.id, session: session)
            if !task.status.isTerminal { try? await transitionAssistantTask(id: task.id, event: .interrupted, text: "Codex 连接中断，进度保留，旧批准已失效。") }
        }
    }
    func continueCompletedExecution(id: String, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.empty }
        try await performAsync { db in
            try db.transaction {
                guard let task = try Self.assistantTask(id, db: db), task.status == .completed, task.scope?.allowCodex == true else { throw AssistantError.invalidTransition }
                var state = try Self.executionState(db, id: id); state.supplements.append(String(text.prefix(8000)))
                state.lastFingerprint = ""; state.repeats = 0; state.stepLimit = max(state.stepLimit, state.calls + 20); state.timeLimitSeconds = state.activeSeconds + 3600
                try Self.saveExecutionState(db, id: id, state: state)
                let row = try db.prepare("UPDATE assistant_tasks SET status='queued',completed_at_ms=NULL,error_code=NULL,updated_at_ms=? WHERE id=?", operation: "continue_completed_agent")
                try row.bind(Self.chatNow(), at: 1); try row.bind(id, at: 2); try row.executeDone()
                try Self.appendAssistantEvent(db, taskID: id, kind: "continued", text: "你补充了修改要求，将继续原任务和原会话。", time: Self.chatNow())
            }
        }
    }
}
