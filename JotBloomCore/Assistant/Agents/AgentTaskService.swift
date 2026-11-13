import Foundation

/// Owns agent lifetimes independently of model loops. Waiting tasks release their
/// slot while their RPC stays alive; user responses are sent only after requeueing.
public actor AgentTaskService {
    private let store: JotBloomStore
    private let connector: any AgentConnector
    private var path: String?
    private var listener: Task<Void, Never>?
    private var sessions: [String: AgentSession] = [:]
    private var waiters: [String: CheckedContinuation<AgentRunOutcome, Error>] = [:]
    private var changed: @Sendable (String) async -> Void = { _ in }
    private var owned: @Sendable (Set<String>) async -> Void = { _ in }
    private var stopping = false
    private var monitor: Task<Void, Never>?
    private var activity: [String: TimeInterval] = [:]
    private var lastUse = ProcessInfo.processInfo.systemUptime
    private var supervisor: AgentSupervisor.Model?
    private var reviewWork: [String: Task<Void, Never>] = [:]
    private var reviewTokens: [String: UUID] = [:]
    private var lastReviewAttempt: [String: TimeInterval] = [:]
    private var reviewInterval: TimeInterval = 45
    private var reviewDelay: TimeInterval = 3
    public init(store: JotBloomStore, connector: any AgentConnector = CodexConnector()) { self.store = store; self.connector = connector }
    public func configure(changed: @escaping @Sendable (String) async -> Void, owned: @escaping @Sendable (Set<String>) async -> Void) async {
        self.changed = changed; self.owned = owned
        await owned((try? await store.ownedAgentThreads()) ?? [])
        if listener == nil { listener = Task { [weak self, connector] in for await event in connector.events { await self?.receive(event) } } }
        if monitor == nil { monitor = Task { [weak self] in while !Task.isCancelled { do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }; await self?.tick() } } }
    }
    public func check(custom: String?, discover: Bool = true) async -> AgentAvailability {
        var found = await CodexConnector.discover(custom: custom)
        guard let path = found.path else { return found }
        do {
            var result = try await connector.connect(path: path); self.path = result.ready ? path : nil
            result.version = found.version; found = result; lastUse = ProcessInfo.processInfo.systemUptime
            if found.status == .unsupported { found.message += " 检测到：" + (found.version ?? "未知版本") }
        } catch { self.path = nil; found.status = .unavailable; found.message = error.localizedDescription; await connector.close() }
        return found
    }
    public func configurePath(_ value: String) { path = value }
    public func configureSupervisor(_ model: AgentSupervisor.Model?, interval: TimeInterval = 45, delay: TimeInterval = 3) {
        supervisor = model; reviewInterval = interval; reviewDelay = delay
    }
    public func session(_ id: String) async throws -> AgentSession {
        if let value = sessions[id] { return value }
        let value = try await store.agentSession(id: id); sessions[id] = value; return value
    }
    private func persist(_ id: String, _ value: AgentSession) async throws {
        sessions[id] = value; try await store.saveAgentSession(id: id, session: value)
    }
    public func run(id: String, instruction: String?, stepID: Int64? = nil) async throws -> AgentRunOutcome {
        guard !stopping, let task = try await store.assistantTask(id: id), let scope = task.scope, scope.allowCodex else { throw ExecutionError.denied("这件事尚未允许派给 Codex。") }
        let state = try await store.executionState(id: id)
        _ = try AssistantResultFiles(directory: scope.outputDirectory, expectedIdentity: state.directoryIdentity)
        var value = try await session(id)
        if let work = scope.workingDirectory {
            let canonical = try AssistantFolders.validateWorking(work), identity = try AssistantFolders.identity(canonical)
            if let expected = value.workIdentity, expected != identity { throw ExecutionError.denied("工作文件夹已被替换或移动，请重新确认任务范围。") }
            value.workIdentity = identity
        }
        if let failure = value.failure { value.failure = nil; try await persist(id, value); throw ExecutionError.unreadable(failure) }
        if value.awaitingInterpretation && instruction == nil { return .finished(value.lastReply) }
        if let pending = value.pending, value.response == nil { _ = pending; return .waiting }
        guard let path else { throw ExecutionError.unreadable("尚未连接 Codex，请在设置中重新检测。") }
        let availability = try await connector.connect(path: path)
        guard availability.ready else { throw ExecutionError.unreadable(availability.message) }
        if let response = value.response, let request = value.pending?.agent {
            value.pending = nil; value.response = nil; value.active = true
            try await persist(id, value)
            try await connector.respond(id: request.requestID, result: response)
        } else if !value.active {
            if let stepID { value.stepID = stepID }
            let hadThread = value.threadID != nil
            if let thread = value.threadID {
                do { try await connector.resume(thread: thread, scope: scope) }
                catch { throw ExecutionError.unreadable("无法恢复原 Codex 会话。请检查 Codex 登录或会话是否已删除；已有文件保留。") }
            }
            else {
                value.threadID = try await connector.create(scope: scope)
                try await persist(id, value)
                await owned((try? await store.ownedAgentThreads()) ?? [])
            }
            var materials: [(AssistantAttachment, String)] = [], remaining = max(0, 40000 - state.materialCharacters)
            let selected = scope.materials + (scope.autoFind ? state.discovered.filter { !scope.materials.contains($0) } : [])
            for item in selected {
                let body: String
                if item.kind == .file {
                    guard FileManager.default.isReadableFile(atPath: item.reference) else { throw ExecutionError.unreadable("选定的参考文件已不存在或不可读：" + item.title) }
                    materials.append((item, "")); continue
                } else {
                    guard remaining > 0 else { continue }
                    body = try await store.executionMaterialText(item)
                }
                let bounded = String(body.prefix(min(7900, remaining))); remaining -= bounded.count
                materials.append((item, bounded + (body.count > bounded.count ? "\n[资料已截断]" : "")))
            }
            let prompt = AssistantPrompts.assignment(task: task, state: state, instruction: value.needsResume ? AssistantPrompts.resume + "\n" + (instruction ?? "") : instruction ?? "继续检查原任务的实际进度。", materials: materials)
            value.active = true; value.needsResume = false; value.awaitingInterpretation = false; value.lastReply = ""; value.turnID = nil
            value.supervision = .init()
            try await persist(id, value)
            let turn = try await connector.start(thread: value.threadID!, scope: scope, prompt: prompt)
            // Notifications may have arrived before the start response. Merge, don't overwrite them.
            value = try await session(id); value.turnID = turn; try await persist(id, value)
            var updatedState = try await store.executionState(id: id)
            updatedState.materialCharacters += materials.reduce(0) { $0 + min(7900, $1.1.count) }
            try? await store.saveExecutionState(id: id, state: updatedState)
            for (material, _) in materials { try await store.recordExecutionMaterial(id: id, material: material, selected: scope.materials.contains(material), sent: true) }
            try await store.agentProgress(id: id, text: hadThread ? "已继续原 Codex 会话，先检查已有进度。" : "已派给 Codex，使用独立会话。")
        }
        activity[id] = ProcessInfo.processInfo.systemUptime; lastUse = ProcessInfo.processInfo.systemUptime
        await changed(id)
        value = try await session(id)
        if let failure = value.failure { throw ExecutionError.unreadable(failure) }
        if value.pending != nil { return .waiting }
        if value.awaitingInterpretation { return .finished(value.lastReply) }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiters[id] = $0 }
        }, onCancel: { Task { await self.stop(id: id) } })
    }
    public func prepareContinuation(_ id: String) async throws {
        var value = try await session(id); guard value.threadID != nil else { throw AssistantError.missing }
        value.needsResume = true; value.awaitingInterpretation = false; try await persist(id, value)
    }
    public func markInterpreted(_ id: String) async throws { var value = try await session(id); guard value.threadID != nil else { return }; value.awaitingInterpretation = false; try await persist(id, value) }
    /// This API is called only from user controls, never registered as a model tool.
    public func answer(id: String, questionID: String, decision: AgentUserDecision, answers: [String: String]) async throws {
        var value = try await session(id)
        guard let question = value.pending, question.id == questionID, value.response == nil,
              try await store.assistantTask(id: id)?.status == .waitingUser else { throw AssistantError.stale }
        value.response = try AgentApprovalPolicy.response(question, decision: decision, answers: answers)
        try await persist(id, value)
        try await store.resolveAgentQuestion(id: id, question: questionID, answer: decision == .decline ? "你拒绝了这次请求。" : decision == .session ? "你允许这项操作在当前任务会话内继续。" : decision == .answer ? "你已回答 Codex 的问题。" : "你允许了这一次请求。", queue: true, payload: value.response)
        await changed(id)
    }
    public func stop(id: String) async {
        reviewWork.removeValue(forKey: id)?.cancel()
        reviewTokens[id] = nil
        guard var value = try? await session(id), value.threadID != nil else { return }
        let thread = value.threadID, turn = value.turnID
        if let pending = value.pending, let request = pending.agent {
            let cancellation: ToolValue?
            if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(request.method) { cancellation = .object(["decision": .string("cancel")]) }
            else { cancellation = try? AgentApprovalPolicy.response(pending, decision: .decline, answers: [:]) }
            if let cancellation { try? await connector.respond(id: request.requestID, result: cancellation) }
            try? await store.resolveAgentQuestion(id: id, question: pending.id, answer: "请求已失效，未再发送批准。", queue: false)
        }
        value.pending = nil; value.response = nil; value.active = false; value.needsResume = thread != nil
        try? await persist(id, value); activity[id] = nil
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if let thread, let turn { await connector.interrupt(thread: thread, turn: turn) }
    }
    /// This path cannot produce command/file/permission approvals. Recheck the
    /// pending request and sources after the model call; stale answers do nothing.
    func answerKnownInput(id: String, questionID: String, action: AssistantStepAction) async throws -> Bool {
        var value = try await session(id)
        guard let pending = value.pending, pending.id == questionID, value.response == nil,
              let request = pending.agent, request.method == "item/tool/requestUserInput",
              let task = try await store.assistantTask(id: id), task.status == .waitingUser, let scope = task.scope,
              let answers = AgentKnownAnswer.answers(action, questions: request.questions, scope: scope, plan: task.plan, state: try await store.executionState(id: id)) else { return false }
        value.response = .object(["answers": .object(answers.mapValues { .object(["answers": .array([.string($0)])]) })])
        try await persist(id, value)
        try await store.resolveAgentQuestion(id: id, question: questionID, answer: AgentKnownAnswer.record(answers), queue: true, payload: value.response)
        await changed(id); return true
    }
    public func shutdown() async {
        stopping = true
        let reviews = Array(reviewWork.values); reviewWork.removeAll(); reviewTokens.removeAll(); reviews.forEach { $0.cancel() }
        for review in reviews { await review.value }
        for id in Array(sessions.keys) {
            let live = sessions[id]?.active == true || sessions[id]?.pending != nil
            await stop(id: id)
            if live { try? await store.transitionAssistantTask(id: id, event: .interrupted, text: "应用暂停，Codex 连接已结束；继续时检查原进度。") }
        }
        await connector.close(); stopping = false
    }
    private func receive(_ event: AgentEvent) async {
        switch event {
        case .closed:
            for id in Array(sessions.keys) {
                guard let value = sessions[id], value.active || value.pending != nil else { continue }
                await stop(id: id)
                try? await store.transitionAssistantTask(id: id, event: .interrupted, text: "Codex 连接已断开，进度保留，可继续。")
                await changed(id)
            }
        case .message(let message): await handle(message)
        }
    }
    private func handle(_ message: ToolValue) async {
        let method = message["method"].text ?? "", params = message["params"]
        guard let thread = params["threadId"].text ?? params["thread"]["id"].text,
              let id = sessions.first(where: { $0.value.threadID == thread })?.key,
              var value = sessions[id] else {
            if message.object["id"] != nil, let codex = connector as? CodexConnector { await codex.reject(id: message["id"]) }; return
        }
        guard value.active || value.pending != nil else { return }
        if let turn = params["turnId"].text, let expected = value.turnID, expected != turn { return }
        do {
            if message.object["id"] != nil {
                guard let scope = try await store.assistantTask(id: id)?.scope else { return }
                if let result = AgentApprovalPolicy.automaticNetwork(method: method, params: params, scope: scope) {
                    try await connector.respond(id: message["id"], result: result)
                    try await store.agentProgress(id: id, text: "依据你已允许的联网范围，为当前 Codex 轮次授予网络权限。"); await changed(id); return
                }
                let detail = params["itemId"].text.flatMap { itemDetails[$0] } ?? ""
                guard value.pending == nil, let question = AgentApprovalPolicy.question(method: method, params: params, id: message["id"], detail: detail) else {
                    if method == "mcpServer/elicitation/request" { try await connector.respond(id: message["id"], result: .object(["action": .string("decline"), "content": .null])) }
                    else if let codex = connector as? CodexConnector { await codex.reject(id: message["id"]) }
                    try await store.agentProgress(id: id, text: "Codex 请求的表单或操作暂不支持，已拒绝。需要登录或复杂表单时，请到 Codex 中处理。"); await changed(id); return
                }
                value.pending = question; try await persist(id, value)
                try await store.waitForExecutionAnswer(id: id, question: question)
                waiters.removeValue(forKey: id)?.resume(returning: .waiting); activity[id] = nil
                // Let the runtime check known facts before presenting an ordinary
                // question. Its completion callback publishes any human fallback.
                let checkKnownAnswer = method == "item/tool/requestUserInput" && question.agent?.questions.allSatisfy({ !AgentKnownAnswer.needsUser($0.text, scope: scope) }) == true
                if !checkKnownAnswer { await changed(id) }
                return
            }
            switch method {
            case "turn/started":
                value.turnID = params["turn"]["id"].text; try await persist(id, value)
            case "item/started", "item/completed":
                let item = params["item"], type = item["type"].text ?? ""
                if type == "fileChange", let key = item["id"].text { if itemDetails.count > 100 { itemDetails.removeAll() }; itemDetails[key] = String(item.json.prefix(16000)) }
                if type == "agentMessage", method == "item/completed", let text = item["text"].text {
                    value.lastReply = String(text.prefix(16000))
                    if value.supervision == nil { value.supervision = .init() }
                    value.supervision?.observe(report: text)
                }
                if type == "fileChange", let root = try await store.assistantTask(id: id)?.scope?.workingDirectory {
                    for change in item["changes"].array {
                        if let path = change["path"].text, AssistantFolders.contains(path, root: root), !value.changedFiles.contains(path) { value.changedFiles.append(path) }
                    }
                }
                try await persist(id, value)
                scheduleReview(id)
                activity[id] = ProcessInfo.processInfo.systemUptime
                if method == "item/completed", ["commandExecution", "fileChange", "webSearch", "mcpToolCall", "agentMessage"].contains(type) {
                    let text = type == "fileChange" ? "Codex 已处理一项文件修改。" : type == "agentMessage" ? "Codex 已更新任务说明。" : type == "webSearch" ? "Codex 正在查阅网页。" : "Codex 已完成一项操作。"
                    try await store.agentProgress(id: id, text: text); await changed(id)
                }
            case "item/agentMessage/delta", "item/commandExecution/outputDelta", "item/reasoning/textDelta":
                activity[id] = ProcessInfo.processInfo.systemUptime
            case "turn/plan/updated":
                activity[id] = ProcessInfo.processInfo.systemUptime
                let steps = params["plan"].array
                if value.supervision == nil { value.supervision = .init() }
                let plan = Array(steps.prefix(8)).map { String(($0["step"].text ?? "").prefix(250)) + " · " + ($0["status"].text ?? "") }
                if value.supervision?.plan != plan { value.supervision?.plan = plan; value.supervision?.revision += 1 }
                try await persist(id, value); scheduleReview(id)
                try await store.agentProgress(id: id, text: "Codex 已更新计划，完成 \(steps.filter { $0["status"].text == "completed" }.count)/\(steps.count) 项。")
                await changed(id)
            case "error":
                if params["willRetry"].bool { try await store.agentProgress(id: id, text: "Codex 遇到暂时错误，正在自行重试。"); await changed(id) }
            case "serverRequest/resolved":
                if let pending = value.pending, pending.agent?.requestID == params["requestId"] {
                    try? await store.resolveAgentQuestion(id: id, question: pending.id, answer: "Codex 已结束这次请求，旧按钮已失效。", queue: true)
                    value.pending = nil; value.response = nil; try await persist(id, value); await changed(id)
                }
            case "turn/completed":
                reviewWork.removeValue(forKey: id)?.cancel()
                reviewTokens[id] = nil
                let turn = params["turn"]
                if let expected = value.turnID, let actual = turn["id"].text, expected != actual { return }
                if turn["status"].text == "interrupted" {
                    if let pending = value.pending { try? await store.resolveAgentQuestion(id: id, question: pending.id, answer: "本轮已中断，旧请求失效。", queue: false) }
                    value.active = false; value.pending = nil; value.response = nil; value.needsResume = true; value.awaitingInterpretation = false
                    try await persist(id, value)
                    try? await store.transitionAssistantTask(id: id, event: .interrupted, text: "Codex 本轮已中断，已有文件保留，可检查后继续。")
                    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()); activity[id] = nil; await changed(id); return
                }
                value.active = false; value.awaitingInterpretation = true
                if value.lastReply.isEmpty { value.lastReply = "Codex 结束了这一轮，但没有返回明确说明。请核对结果，不能直接视为完成。" }
                if turn["status"].text == "failed" {
                    let error = turn["error"].json.lowercased()
                    value.failure = error.contains("usage") || error.contains("quota") || error.contains("limit") ? "Codex 额度或调用频率达到上限，请检查 Codex 后重试；已有文件保留。" : error.contains("auth") || error.contains("login") || error.contains("401") ? "Codex 需要重新登录，请在 Codex 中处理；已有文件保留。" : "Codex 执行出错；请检查 Codex 状态，已有文件保留。"
                    value.lastReply = value.failure!
                }
                if turn["status"].text == "interrupted" { value.lastReply = "Codex 本轮被中断，结果可能不完整。" + value.lastReply }
                if let pending = value.pending { try? await store.resolveAgentQuestion(id: id, question: pending.id, answer: "本轮已结束，旧请求失效。", queue: true) }
                value.pending = nil; value.response = nil; try await persist(id, value)
                activity[id] = nil; lastUse = ProcessInfo.processInfo.systemUptime
                if let failure = value.failure { try await store.failAgentExecution(id: id, message: failure); waiters.removeValue(forKey: id)?.resume(throwing: ExecutionError.unreadable(failure)) } else { waiters.removeValue(forKey: id)?.resume(returning: .finished(value.lastReply)) }; await changed(id)
            default: break
            }
        } catch {
            await stop(id: id)
            try? await store.transitionAssistantTask(id: id, event: .interrupted, text: "Codex 状态未能完整保存，已暂停；已有文件保留。")
            await changed(id)
        }
    }
    private var itemDetails: [String: String] = [:]
    /// User-authored direction goes to the current turn; it never answers an approval.
    public func steerFromUser(id: String, text: String) async throws -> Bool {
        let value = try await session(id)
        guard value.active, value.pending == nil, let thread = value.threadID, let turn = value.turnID,
              try await store.assistantTask(id: id)?.status == .running else { return false }
        reviewWork.removeValue(forKey: id)?.cancel()
        reviewTokens[id] = nil
        try await connector.steer(thread: thread, turn: turn, prompt: "用户补充要求（权限范围不变，需要新权限仍须请求批准）：\n" + String(text.prefix(8000)))
        var current = try await session(id)
        if current.turnID == turn {
            if current.supervision == nil { current.supervision = .init() }
            current.supervision?.revision += 1
            current.supervision?.summary = "补充已送达 Codex，接下来会核对落实情况。"
            try await persist(id, current)
            try await store.agentProgress(id: id, text: "你的补充已送达当前 Codex 任务。", kind: "supplementDelivered")
            scheduleReview(id); await changed(id)
        }
        return true
    }
    private func scheduleReview(_ id: String) {
        guard supervisor != nil, !stopping, reviewWork[id] == nil,
              let value = sessions[id], value.active, value.pending == nil,
              let review = value.supervision, review.revision > review.reviewedRevision else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - (lastReviewAttempt[id] ?? 0)
        let delay = max(reviewDelay, reviewInterval - elapsed)
        let token = UUID(); reviewTokens[id] = token
        reviewWork[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)); try Task.checkCancellation() }
            catch { return }
            await self?.review(id, token: token)
        }
    }
    private func review(_ id: String, token: UUID) async {
        defer {
            if reviewTokens[id] == token { reviewWork[id] = nil; reviewTokens[id] = nil; if !Task.isCancelled { scheduleReview(id) } }
        }
        guard !stopping, let supervisor, let snapshot = try? await session(id), snapshot.active, snapshot.pending == nil,
              let observed = snapshot.supervision, let turn = snapshot.turnID, let thread = snapshot.threadID,
              observed.revision > observed.reviewedRevision else { return }
        lastReviewAttempt[id] = ProcessInfo.processInfo.systemUptime
        do {
            guard let task = try await store.assistantTask(id: id), task.status == .running, let scope = task.scope else { return }
            let state = try await store.executionState(id: id)
            let context = AgentSupervisor.context(scope: scope, supplements: state.supplements, session: snapshot)
            guard try await store.reserveSupervisionBudget(id: id, estimatedTokens: ChatContext.estimate(AgentSupervisor.instructions + context) + 1024) else {
                try await pauseForSupervision(id, text: "监督和执行已达到本次用量上限，已有结果保留。", kind: "budget"); return
            }
            let raw = try await supervisor(context); try Task.checkCancellation()
            var current = try await session(id)
            guard !stopping, current.active, current.pending == nil, current.turnID == turn,
                  current.supervision?.revision == observed.revision else { return }
            let decision = try AgentSupervisor.parse(raw, session: snapshot)
            current.supervision?.failures = 0
            current.supervision?.reviewedRevision = observed.revision
            current.supervision?.reviewedAt = Date()
            current.supervision?.summary = decision.summary
            try await persist(id, current)
            switch decision.action {
            case .onTrack:
                try await store.agentProgress(id: id, text: decision.summary, kind: "supervision")
            case .correct:
                if scope.permissionMode == AssistantPermissionMode.askAlways.rawValue || (current.supervision?.corrections ?? 0) >= 2 {
                    try await pauseForSupervision(id, text: "需要你确认接下来的方向：" + decision.summary + "\n可以补充要求，或按原目标继续。")
                    return
                }
                let live = try await session(id)
                guard live.active, live.pending == nil, live.turnID == turn else { return }
                try await connector.steer(thread: thread, turn: turn, prompt: AgentSupervisor.correction(scope: scope, supplements: state.supplements))
                current = try await session(id)
                guard current.turnID == turn, current.active else { return }
                current.supervision?.corrections += 1
                current.supervision?.summary = "已提醒 Codex 回到原要求：" + decision.summary
                try await persist(id, current)
                try await store.agentProgress(id: id, text: current.supervision?.summary ?? decision.summary, kind: "supervisionCorrection")
            case .askUser:
                try await pauseForSupervision(id, text: decision.question ?? decision.summary); return
            }
            await changed(id)
        } catch {
            guard !Task.isCancelled, !stopping, var current = try? await session(id), current.active, current.pending == nil, current.turnID == turn,
                  current.supervision?.revision == observed.revision else { return }
            current.supervision?.failures += 1
            current.supervision?.summary = "这次监督未能完成，尚不能判断方向；稍后重试。"
            try? await persist(id, current)
            if (current.supervision?.failures ?? 0) >= 2 {
                try? await pauseForSupervision(id, text: "连续两次未能完成监督，已暂停 Codex。请检查进展后决定是否继续。")
            } else {
                try? await store.agentProgress(id: id, text: "监督暂时不可用，稍后重试。", kind: "supervision")
                await changed(id)
            }
        }
    }
    private func pauseForSupervision(_ id: String, text: String, kind: String = "supervision") async throws {
        var value = try await session(id)
        guard value.active, value.pending == nil else { return }
        let thread = value.threadID, turn = value.turnID
        value.active = false; value.needsResume = true; value.awaitingInterpretation = false
        try await persist(id, value)
        if let thread, let turn { await connector.interrupt(thread: thread, turn: turn) }
        try await store.waitForExecutionAnswer(id: id, question: .init(kind: kind, text: text))
        waiters.removeValue(forKey: id)?.resume(returning: .waiting); activity[id] = nil
        await changed(id)
    }
    public func lastProgress(_ id: String) -> TimeInterval? { activity[id] }
    private func tick() async {
        let now = ProcessInfo.processInfo.systemUptime
        if sessions.values.allSatisfy({ !$0.active && $0.pending == nil }), now - lastUse >= 300 {
            await connector.close(); itemDetails.removeAll(); sessions.removeAll(); activity.removeAll(); lastUse = now
        }
    }
}
