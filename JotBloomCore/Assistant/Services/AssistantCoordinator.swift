import Combine
import Foundation

@MainActor
public final class AssistantCoordinator: ObservableObject {
    @Published public private(set) var tasks: [AssistantTask] = []
    @Published public private(set) var links: [String: AssistantTaskLink] = [:]
    @Published public private(set) var deliveredReminders: [AssistantReminder] = []
    @Published public private(set) var ready = false
    @Published public private(set) var feedback: String?
    public var onReceived: ((AssistantTask) -> Void)?
    public var modelConfigured: () -> Bool = { false }
    public var understand: ((UnderstandingInput) async throws -> TaskBrief)?
    public var routeIntent: ((String, ChatTurn?, Bool) async -> AssistantIntent)?
    public var executionModel: TaskRuntime.Model? { didSet { scheduleExecution() } }
    public var supervisionModel: AgentSupervisor.Model? {
        didSet { let model = supervisionModel; Task { await agentService.configureSupervisor(model) } }
    }
    public var onUpdate: ((AssistantTask) -> Void)?
    public var onReminder: (([AssistantReminder], Bool) -> Void)?
    public let reminders: ReminderScheduler
    public let agentSettings: AssistantAgentSettings
    public let agentService: AgentTaskService
    @Published public private(set) var agentAvailability = AgentAvailability()
    @Published public private(set) var checkingAgent = false
    private var work: [String: Task<Void, Never>] = [:]
    private var configurationWork: Task<Void, Never>?
    private var executionWork: [String: Task<Void, Never>] = [:]
    private var executionMonitors: [String: Task<Void, Never>] = [:]
    private var executionActivity: [String: TimeInterval] = [:]
    private var workIDs: [String: UUID] = [:]
    private let store: JotBloomStore
    private var paused = false
    private var operations = 0
    public var hasPendingWrites: Bool { operations > 0 || !work.isEmpty || !executionWork.isEmpty || reminders.hasPendingWrites || (!paused && tasks.contains { $0.scope?.allowCodex == true && $0.status == .waitingUser }) }
    public var runningExecutionCount: Int { executionWork.count }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var revision = 0
    public init(store: JotBloomStore, defaults: UserDefaults = .standard, agentConnector: any AgentConnector = CodexConnector()) {
        self.store = store; agentSettings = AssistantAgentSettings(defaults: defaults); agentService = AgentTaskService(store: store, connector: agentConnector); reminders = ReminderScheduler(store: store)
        reminders.onDue = { [weak self] values, missed in
            self?.onReminder?(values, missed)
            Task { @MainActor in try? await self?.reload() }
        }
    }

    public func start() async {
        guard !ready else { return }
        do {
            try await store.recoverAgentSessions()
            await agentService.configure(changed: { [weak self] id in await self?.agentChanged(id) }, owned: { values in await MainActor.run { AssistantOwnedThreads.ids.formUnion(values) } })
            await agentService.configureSupervisor(supervisionModel)
            try await store.recoverAssistantTasks(); try await reload(); ready = true
            await reminders.start()
            for task in tasks where task.status == .received { scheduleUnderstanding(task.id) } }
        catch { feedback = "任务读取未完成，请重试。" }
    }
    public func reload() async throws {
        revision += 1; let expected = revision
        let tasks = try await store.assistantTasks(), links = try await store.assistantTaskLinks()
        let reminders = try await store.assistantReminders().filter { $0.state != "pending" }
        guard revision == expected else { return }
        self.deliveredReminders = reminders
        self.tasks = tasks; self.links = Dictionary(uniqueKeysWithValues: links.map { ($0.turn, $0) })
    }
    public func group(for task: AssistantTask) -> AssistantTaskGroup? {
        deliveredReminders.contains { $0.taskID == task.id } ? .attention : task.status.group
    }
    public var attentionCount: Int { tasks.filter { group(for: $0) == .attention }.count }
    public var entryTitle: String {
        if attentionCount > 0 { return "\(attentionCount) 件等你处理" }
        let count = tasks.filter { $0.status.group == .active }.count
        return count > 0 ? "\(count) 件进行中" : "任务"
    }
    private func beginOperation() throws {
        guard ready, !paused else { throw AssistantError.unavailable }
        operations += 1
    }
    private func endOperation() {
        operations -= 1
        if operations == 0 { let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
    }
    public func pauseAndDrain() async {
        paused = true; configurationWork?.cancel(); await reminders.pauseAndDrain()
        executionMonitors.values.forEach { $0.cancel() }; executionMonitors.removeAll()
        await agentService.shutdown()
        for value in executionWork.values { value.cancel() }
        for value in Array(executionWork.values) { await value.value }
        for value in work.values { value.cancel() }
        for value in Array(work.values) { await value.value }
        if operations > 0 { await withCheckedContinuation { waiters.append($0) } }
        try? await reload()
    }
    public func resume() { paused = false; Task { await reminders.start() }; scheduleExecution() }
    @discardableResult
    public func receive(input: String, source: AssistantSource, attachments: [AssistantAttachment] = [],
                        id: String = UUID().uuidString, turn: ChatTurn? = nil) async throws -> AssistantTask {
        try beginOperation(); defer { endOperation() }
        let saved = try await store.createAssistantTask(id: id, input: input, source: source, attachments: attachments,
                                                       session: turn?.session, turn: turn?.token, modelConfigured: modelConfigured())
        try? await reload()
        onReceived?(saved)
        if saved.status == .received { scheduleUnderstanding(saved.id) }
        return saved
    }
    public func submitChat(input: String, attachments: [AssistantAttachment], token: String,
                           session: String, systemPrompt: String) async throws -> ChatTurn {
        try beginOperation(); defer { endOperation() }
        let row = try await store.submitAssistantChat(input: input, attachments: attachments, token: token,
                                                     expectedSession: session, systemPrompt: systemPrompt)
        try? await reload()
        if let saved = tasks.first(where: { $0.chatTurn == row.token }) { onReceived?(saved); scheduleUnderstanding(saved.id) }
        return row
    }
    public func cancel(id: String) async throws {
        try beginOperation(); defer { endOperation() }
        await agentService.stop(id: id)
        if let running = executionWork[id] { running.cancel(); await running.value }
        work[id]?.cancel(); workIDs[id] = nil
        try await store.transitionAssistantTask(id: id, event: .cancelled, text: "你取消了这件事，未执行的提醒已取消。")
        try await reload(); await reminders.refresh()
        if let task = tasks.first(where: { $0.id == id }) { onUpdate?(task) }
    }
    public func delete(id: String) async throws {
        try beginOperation(); defer { endOperation() }
        try await store.deleteAssistantTask(id: id); try await reload()
    }
    public func detail(id: String) async throws -> (materials: [AssistantAttachment], events: [AssistantTaskEvent]) {
        (try await store.assistantMaterials(taskID: id), try await store.assistantEvents(taskID: id))
    }
    public func configurationChanged() {
        configurationWork?.cancel()
        configurationWork = Task { [weak self] in
            guard let self else { return }
            for value in self.work.values { value.cancel() }
            for value in Array(self.work.values) { await value.value }
            guard !Task.isCancelled, self.ready, !self.paused, self.modelConfigured() else { return }
            for task in self.tasks where task.errorCode == "modelNotConfigured" || (task.status == .interrupted && task.scope == nil) {
                self.scheduleUnderstanding(task.id)
            }
        }
    }
    public func retry(_ id: String, answers: [String: String]? = nil, adjustment: String? = nil) {
        guard work[id] == nil else { return }
        scheduleUnderstanding(id, answers: answers, adjustment: adjustment)
    }
    private func scheduleUnderstanding(_ id: String, answers: [String: String]? = nil, adjustment: String? = nil) {
        guard !paused, let understand, work[id] == nil else { return }
        let generation = UUID(); workIDs[id] = generation
        work[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.work[id] = nil; self.workIDs[id] = nil }
            do {
                try self.beginOperation(); defer { self.endOperation() }
                guard self.modelConfigured() else {
                    try await self.store.failAssistantUnderstanding(id: id, configuration: true, message: "先配置模型，交办内容已保存。")
                    try await self.reload(); return
                }
                let previousTask = try await self.store.assistantTask(id: id)
                try await self.store.beginAssistantUnderstanding(id: id, answer: answers, adjustment: adjustment)
                try await self.reload(); if let task = self.tasks.first(where: { $0.id == id }) { self.onUpdate?(task) }
                let input = try await self.store.assistantUnderstandingInput(id: id, now: Date(), timeZone: .current)
                var brief = try await understand(input)
                try TaskBriefValidator.validate(brief, timeZone: input.timeZone)
                guard input.questionRounds < 2 || brief.questions.isEmpty else { throw SettingsError.responseInvalid }
                try Task.checkCancellation()
                let now = Int64(input.now.timeIntervalSince1970 * 1000)
                let due = AssistantDates.deadline(brief.deadline, timeZone: input.timeZone)
                let explicit = brief.remindAt.flatMap { AssistantDates.parse($0, timeZone: input.timeZone) }
                var times = AssistantDates.reminders(due: due, explicit: explicit, now: now, timeZone: input.timeZone,
                    dayBeforeMinute: self.agentSettings.reminderDayBefore, sameDayMinute: self.agentSettings.reminderSameDay)
                if !brief.needsWork, times.isEmpty, brief.questions.isEmpty {
                    if let due, due > now { times = [due] }
                    else {
                        guard input.questionRounds < 2 else { throw SettingsError.responseInvalid }
                        brief.questions = [.init(id: "reminderTime", text: "希望在什么具体日期和时间提醒？", kind: "text", options: [])]
                    }
                }
                let attached = try await self.store.assistantMaterials(taskID: id)
                let candidates = try await self.store.assistantMaterialCandidates(keywords: brief.keywords)
                var materials = attached.map { AssistantMaterial($0, selected: $0.kind != .chat) }
                let known = Set(materials.map(\.id))
                materials += candidates.filter { !known.contains($0.id) }.enumerated().map { AssistantMaterial($0.element, selected: $0.offset < 3) }
                materials = try await self.store.assistantCheckedMaterials(materials)
                let output = AssistantOutputLocation.suggested(title: brief.title, now: input.now, reserved: self.tasks.compactMap { $0.plan?.outputDirectory }, parentPath: self.agentSettings.outputParent)
                var plan = AssistantPlan(brief: brief, dueAt: due, reminders: times, materials: materials, outputDirectory: output)
                if explicit != nil { plan.reminderOrigins = Dictionary(uniqueKeysWithValues: times.map { (String($0), .explicit) }) }
                if var previous = previousTask?.plan, previousTask?.status == .planReady || previous.reminderOrigins != nil {
                    previous.reschedule(due: due, now: now, timeZone: input.timeZone,
                        dayBeforeMinute: self.agentSettings.reminderDayBefore, sameDayMinute: self.agentSettings.reminderSameDay)
                    plan.reminders = previous.reminders; plan.reminderOrigins = previous.reminderOrigins
                }
                plan.allowCodex = brief.needsCodex
                plan.restrictCodex(to: self.agentAvailability)
                // A suggestion is only a visible default. Start is the sole grant.
                plan.permissionMode = self.agentSettings.mode.rawValue
                plan.autoFind = self.agentSettings.mode != .askAlways
                plan.allowNetwork = self.agentSettings.mode != .askAlways && brief.needsNetwork
                try Task.checkCancellation(); guard self.workIDs[id] == generation else { return }
                try await self.store.saveAssistantUnderstanding(id: id, brief: brief, plan: plan,
                    directReminder: !brief.needsWork && brief.questions.isEmpty && !plan.reminders.isEmpty)
                try await self.reload(); await self.reminders.refresh()
                if let task = self.tasks.first(where: { $0.id == id }) { self.onUpdate?(task) }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    if self.workIDs[id] == generation {
                        try? await self.store.transitionAssistantTask(id: id, event: .interrupted, text: "理解已暂停，内容保留，可继续。")
                        try? await self.reload()
                    }
                    return
                }
                guard self.workIDs[id] == generation else { return }
                let configuration = (error as? SettingsError)?.isCredentialIssue == true
                try? await self.store.failAssistantUnderstanding(id: id, configuration: configuration,
                    message: "没能理解：" + ChatViewModel.message(error) + " 可以重试或改写。")
                try? await self.reload()
                if let task = self.tasks.first(where: { $0.id == id }) { self.onUpdate?(task) }
            }
        }
    }
    public func savePlanDraft(id: String, plan: AssistantPlan) async throws {
        try beginOperation(); defer { endOperation() }
        var plan = plan; plan.restrictCodex(to: agentAvailability)
        try await store.saveAssistantPlanDraft(id: id, plan: plan)
        if let index = tasks.firstIndex(where: { $0.id == id && $0.status == .planReady }) { tasks[index].plan = plan }
    }
    public func confirm(id: String, plan: AssistantPlan) async throws {
        try beginOperation(); defer { endOperation() }
        var checked = plan
        if checked.allowCodex {
            guard agentAvailability.ready else { throw ExecutionError.unreadable(agentAvailability.message) }
            if let path = checked.workingDirectory { checked.workingDirectory = try AssistantFolders.validateWorking(path) }
        }
        checked.materials = try await store.assistantCheckedMaterials(plan.materials)
        if checked.materials != plan.materials {
            try await store.refreshAssistantPlan(id: id, plan: checked); try await reload()
            throw AssistantError.stale
        }
        try await store.confirmAssistantPlan(id: id, plan: checked, now: Int64(Date().timeIntervalSince1970 * 1000))
        try await reload(); await reminders.refresh()
        if let task = tasks.first(where: { $0.id == id }) { onUpdate?(task) }
        scheduleExecution()
    }
    private func scheduleExecution() {
        guard ready, !paused, let model = executionModel else { return }
        let occupied = Set(tasks.filter { executionWork[$0.id] != nil }.map { $0.scope?.allowCodex == true })
        guard let task = tasks.filter({ $0.status == .queued && $0.scope != nil && executionWork[$0.id] == nil && !occupied.contains($0.scope?.allowCodex == true) }).min(by: { $0.createdAt < $1.createdAt }) else { return }
        let id = task.id
        let started = ProcessInfo.processInfo.systemUptime
        executionActivity[id] = started
        let runtime = TaskRuntime(store: store, model: model, agent: agentService, changed: { [weak self] in await self?.executionChanged(id) })
        executionWork[id] = Task { [weak self] in
            await runtime.run(id: id)
            guard let self else { return }
            self.executionWork[id] = nil
            self.executionMonitors.removeValue(forKey: id)?.cancel(); self.executionActivity[id] = nil
            await self.executionChanged(id)
            self.scheduleExecution()
        }
        scheduleExecution()
        executionMonitors[id] = Task { [weak self] in
            guard let self else { return }
            let initial = try? await self.store.executionState(id: id)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard !self.paused, let running = self.executionWork[id], self.tasks.first(where: { $0.id == id })?.status == .running else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let alert = TaskWatchdog.check(activeSeconds: (initial?.activeSeconds ?? 0) + now - started, idleSeconds: now - max(self.executionActivity[id] ?? now, await self.agentService.lastProgress(id) ?? 0), waiting: false, sleeping: false, timeLimit: initial?.timeLimitSeconds ?? 3600) {
                    await self.agentService.stop(id: id)
                    running.cancel(); await running.value
                    try? await self.store.waitForExecutionAnswer(id: id, question: .init(kind: alert == .stalled ? "stuck" : "overtime", text: alert == .stalled ? "超过十分钟没有进展，好像卡住了。继续等还是停止？" : "这件事已经运行一小时，继续吗？"))
                    await self.executionChanged(id); return
                }
            }
        }
    }
    public func checkAgent() async {
        guard !checkingAgent else { return }
        checkingAgent = true; defer { checkingAgent = false }
        agentAvailability = await agentService.check(custom: agentSettings.executable)
        if !agentAvailability.ready {
            for task in tasks where task.status == .planReady {
                guard var plan = task.plan, plan.allowCodex else { continue }
                plan.restrictCodex(to: agentAvailability)
                do { try await savePlanDraft(id: task.id, plan: plan) }
                catch { feedback = "Codex 当前不可用，计划的开关状态未能保存，请重试。" }
            }
        }
    }
    private func agentChanged(_ id: String) async {
        await executionChanged(id); scheduleExecution()
    }
    public func agentDetails(_ id: String) async throws -> AgentSession { try await agentService.session(id) }
    public func answerAgent(_ id: String, question: String, decision: AgentUserDecision, answers: [String: String] = [:]) async throws {
        try beginOperation(); defer { endOperation() }
        try await agentService.answer(id: id, questionID: question, decision: decision, answers: answers)
        try await reload(); scheduleExecution()
    }
    public func continueCompleted(_ id: String, text: String) async throws {
        try beginOperation(); defer { endOperation() }
        try await agentService.prepareContinuation(id)
        try await store.continueCompletedExecution(id: id, text: text); try await reload(); scheduleExecution()
    }
    private func executionChanged(_ id: String) async {
        let previous = tasks.first { $0.id == id }?.status
        let previousUpdate = tasks.first { $0.id == id }?.updatedAt
        try? await reload(); await reminders.refresh()
        if let task = tasks.first(where: { $0.id == id }), task.status == .running, task.updatedAt != previousUpdate { executionActivity[id] = ProcessInfo.processInfo.systemUptime }
        if let task = tasks.first(where: { $0.id == id }), (task.status != previous || (task.status == .waitingUser && task.updatedAt != previousUpdate)) { onUpdate?(task) }
    }
    public func continueExecution(_ id: String) async throws {
        try beginOperation(); defer { endOperation() }
        try await store.resumeExecution(id: id); try await reload(); scheduleExecution()
    }
    public func answerExecution(_ id: String, question: String, allow: Bool, selected: Set<String> = [], answer: String = "") async throws {
        try beginOperation(); defer { endOperation() }
        if allow, let pending = try await store.executionQuestion(id: id), pending.scopeKind == "codex", !agentAvailability.ready { throw ExecutionError.unreadable(agentAvailability.message) }
        try await store.answerExecutionQuestion(id: id, questionID: question, allow: allow, selected: selected, answer: answer)
        try await reload(); await reminders.refresh(); scheduleExecution()
    }
    public func supplementExecution(_ id: String, text: String) async throws {
        try beginOperation(); defer { endOperation() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.empty }
        let agent = try await agentService.session(id)
        if agent.active, agent.turnID != nil {
            try await store.supplementExecution(id: id, text: text)
            if agent.pending == nil {
                do {
                    if try await agentService.steerFromUser(id: id, text: text) { try await reload(); return }
                } catch {
                    try await store.agentProgress(id: id, text: "补充已保存，但未能确认送达当前轮次；不会自动重复发送。", kind: "supplementDeliveryUnknown")
                    try await reload(); throw error
                }
            }
            try await reload(); return
        }
        if let running = executionWork[id] { running.cancel(); await running.value }
        try await store.supplementExecution(id: id, text: text)
        if tasks.first(where: { $0.id == id })?.status == .interrupted { try await store.resumeExecution(id: id) }
        try await reload(); scheduleExecution()
    }
    public func executionDetails(_ id: String) async throws -> (steps: [AssistantExecutionStep], question: AssistantRuntimeQuestion?, materials: [AssistantMaterialUsage], files: [AssistantResultFile]) {
        let task = try await store.assistantTask(id: id), state = try await store.executionState(id: id)
        let files = task?.scope.flatMap { try? AssistantResultFiles(directory: $0.outputDirectory, expectedIdentity: state.directoryIdentity, create: false).list(allTypes: $0.allowCodex) } ?? []
        return (try await store.executionSteps(id: id), try await store.executionQuestion(id: id), try await store.executionMaterialUsage(id: id), files)
    }
    public func undoExecution(_ id: String, step: Int64) async throws {
        try beginOperation(); defer { endOperation() }
        try await store.undoExecutionEffect(id: id, stepID: step); try await reload(); await reminders.refresh()
    }
    public func readExecutionResult(_ id: String, name: String) async throws -> String {
        guard AssistantResultFiles.supportsTextActions(name) else { throw ExecutionError.denied("此类型仅支持打开和在访达中显示。") }
        guard let scope = try await store.assistantTask(id: id)?.scope else { throw AssistantError.missing }
        let state = try await store.executionState(id: id)
        return try AssistantResultFiles(directory: scope.outputDirectory, expectedIdentity: state.directoryIdentity, create: false).read(name, allTypes: true)
    }
    public func readExecutionImage(_ id: String, name: String) async throws -> Data {
        guard let scope = try await store.assistantTask(id: id)?.scope else { throw AssistantError.missing }
        let state = try await store.executionState(id: id)
        return try AssistantResultFiles(directory: scope.outputDirectory, expectedIdentity: state.directoryIdentity, create: false).readImage(name)
    }
    public func saveExecutionResult(_ id: String, name: String) async throws {
        try beginOperation(); defer { endOperation() }
        let text = try await readExecutionResult(id, name: name)
        // This is an explicit user save, bounded by the 1 MB result reader.
        // Keep the original text; the model tool's separate 20000-character limit remains.
        let action = AssistantStepAction(tool: .saveInspiration, args: ["content": .string(text)])
        let step = try await store.beginExecutionStep(id: id, action: action, decision: "user", userInitiated: true)
        _ = try await store.executeRecordedEffect(id: id, stepID: step, action: action, userInitiated: true)
        try await reload()
    }
    public func availableMaterials() async throws -> [AssistantAttachment] {
        let library = try await store.assistantMaterialCandidates(keywords: [], all: true)
        let shelf = try await store.loadFileShelf()
        return library + shelf.map { .file($0.url) }
    }
    public func pendingReminders() async throws -> [AssistantReminder] { try await store.assistantReminders() }
    public func resolveReminders(_ ids: [String], snooze: Bool) async throws {
        try beginOperation(); defer { endOperation() }
        try await store.resolveAssistantReminders(ids: ids, snooze: snooze, now: Int64(Date().timeIntervalSince1970 * 1000))
        try await reload(); await reminders.refresh()
    }
    public func routeChat(_ turn: ChatTurn, history: [ChatTurn], allowNote: Bool) async throws -> AssistantChatResult {
        guard let routeIntent else { return .chat }
        try beginOperation(); defer { endOperation() }
        let intent = await routeIntent(turn.user, history.last, allowNote)
        try Task.checkCancellation()
        let result = try await store.commitAssistantRoute(turn: turn, intent: intent)
        if case .task = intent {
            try await reload()
            if let saved = tasks.first(where: { $0.chatTurn == turn.token }) { onReceived?(saved); scheduleUnderstanding(saved.id) }
        }
        return result
    }

}
