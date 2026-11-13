import AppKit
import Combine
import JotBloomCore

/// App-owned lifetime. Every write goes through the coordinator before shutdown
/// or moving the database; no assistant service reads clipboard history.
@MainActor
final class AssistantAssembly {
    let coordinator: AssistantCoordinator
    let viewModel: AssistantViewModel
    let island = AssistantIslandController()
    let drop = AssistantDropCoordinator()
    let menuDrop = AssistantMenuDrop()
    private var startup: Task<Void, Never>?
    private var sleepPause: Task<Void, Never>?
    private var taskObservation: AnyCancellable?
    private var quietObservation: AnyCancellable?
    var onPendingChanged: (Bool) -> Void = { _ in }
    private var taskNeedsAttention = false
    private var eventIDs: [String: Set<UUID>] = [:]
    private var paused = false
    private var observers: [NSObjectProtocol] = []
    private var approvalQuestions: [UUID: String] = [:]
    private var reminderEvents: [UUID: [String]] = [:]
    private var reminderContents: [UUID: ([AssistantReminder], Bool)] = [:]
    private var dropWrites: [String: Task<Void, Never>] = [:]
    var hasPendingWrites: Bool { !dropWrites.isEmpty || menuDrop.hasPendingWrites || coordinator.hasPendingWrites }
    private var failedDrops: [String: (String, [AssistantAttachment])] = [:]
    var openTask: (String) -> Bool = { _ in false }
    var openTasks: () -> Bool = { false }
    var openSettings: () -> Bool = { false }
    var canInteract: () -> Bool = { false }
    var panelVisible: () -> Bool = { false }

    init(store: JotBloomStore, chat: ChatViewModel, defaults: UserDefaults = .standard) {
        coordinator = AssistantCoordinator(store: store, defaults: defaults)
        viewModel = AssistantViewModel(coordinator: coordinator)
        viewModel.onSystemInteraction = { [weak chat] active in chat?.onSystemInteraction?(active) }
        coordinator.modelConfigured = { [weak chat] in chat?.configured == true }
        chat.onSubmitTask = { [weak coordinator] input, attachments, token, session, prompt in
            guard let coordinator else { throw AssistantError.unavailable }
            return try await coordinator.submitChat(input: input, attachments: attachments, token: token, session: session, systemPrompt: prompt)
        }
        chat.onRoute = { [weak coordinator] turn, history, allowNote in
            guard let coordinator else { return .chat }
            return try await coordinator.routeChat(turn, history: history, allowNote: allowNote)
        }
        coordinator.onUpdate = { [weak self] task in self?.updated(task) }
        coordinator.onReminder = { [weak self] values, missed in self?.showReminders(values, missed: missed) }
        coordinator.onReceived = { [weak self] task in self?.received(task) }
        taskObservation = coordinator.$tasks.sink { [weak self] tasks in
            guard let self else { return }
            self.island.setRunning(tasks.contains { $0.status == .running })
            self.taskNeedsAttention = tasks.contains { $0.status.group == .attention }
            self.refreshPending()
            let active = Set(tasks.filter { !$0.status.isTerminal }.map(\.id))
            for (event, stored) in self.reminderContents {
                let remaining = stored.0.filter { value in active.contains(value.taskID) && self.coordinator.deliveredReminders.contains { $0.id == value.id } }
                if remaining.count != stored.0.count {
                    self.island.resolve([event]); self.reminderEvents[event] = nil; self.reminderContents[event] = nil
                    if !remaining.isEmpty { self.showReminders(remaining, missed: stored.1) }
                }
            }
            for id in Array(self.eventIDs.keys) where !active.contains(id) {
                self.island.resolve(self.eventIDs.removeValue(forKey: id) ?? [])
            }
        }
        drop.allowed = { [weak self] in
            guard let self else { return false }
            return !self.paused && self.coordinator.ready && self.canInteract() && self.island.gate.allowsPresentation
        }
        drop.receive = { [weak self] input, attachments, id in self?.receiveDrop(input, attachments: attachments, id: id) }
        menuDrop.allowed = { [weak self] in
            guard let self else { return false }
            // Unlike passive island notifications this is a deliberate user action.
            return !self.paused && self.coordinator.ready && self.canInteract()
        }
        menuDrop.receive = { [weak self] input, attachments, id in self?.receiveDrop(input, attachments: attachments, id: id) }
        menuDrop.feedback = { [weak self] success, message in
            self?.island.receive(.init(priority: success ? .received : .failed, tone: success ? .green : .red,
                                      compactText: message, title: message, policy: success ? .received : .init(seconds: 8, keepsPending: false)))
        }
        island.onPendingChanged = { [weak self] _ in self?.refreshPending() }
        quietObservation = coordinator.agentSettings.$quiet.removeDuplicates().sink { [weak self] in self?.island.quiet = $0 }
        island.gate.panelIsVisible = { [weak self] in self?.panelVisible() == true }
        island.onAction = { [weak self] action, events in
            guard let self, self.canInteract() else { return false }
            if ["ack", "snooze"].contains(action.id) {
                let ids = events.flatMap { self.reminderEvents[$0.id] ?? [] }
                Task {
                    do {
                        try await self.coordinator.resolveReminders(ids, snooze: action.id == "snooze")
                        self.island.resolve(Set(events.map(\.id)))
                        for event in events { self.reminderEvents[event.id] = nil; self.reminderContents[event.id] = nil }
                    } catch { self.viewModel.feedback = error.localizedDescription }
                }
                return false
            }
            if ["approveOnce", "declineAgent"].contains(action.id), let event = events.first, let taskID = event.taskID, let question = self.approvalQuestions[event.id] {
                Task {
                    do { try await self.coordinator.answerAgent(taskID, question: question, decision: action.id == "approveOnce" ? .once : .decline)
                        self.island.resolve([event.id]); self.approvalQuestions[event.id] = nil
                    } catch { self.viewModel.feedback = error.localizedDescription }
                }; return false
            }
            if action.id == "undoReminder", let id = events.first?.taskID {
                Task { _ = await self.viewModel.cancel(id) }; return false
            }
            if action.id == "showUpdates" { _ = self.openTasks(); return false }
            if action.id == "settings" { _ = self.openSettings(); return false }
            if action.id == "retry", let id = events.first?.taskID, let payload = self.failedDrops[id] {
                self.receiveDrop(payload.0, attachments: payload.1, id: id); return true
            }
            if let id = events.first?.taskID { _ = self.openTask(id); return false }
            return false
        }
    }
    func start() {
        island.start()
        for name in [NSNotification.Name.NSSystemClockDidChange, NSNotification.Name.NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.coordinator.reminders.refresh(missed: true) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleepPause = Task { @MainActor in await self?.pauseAndDrain() } }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.sleepPause?.value; self?.resume()
                await self?.coordinator.reminders.refresh(missed: true)
            }
        })
        startup = Task { [weak self] in await self?.coordinator.start(); await self?.coordinator.checkAgent() }
    }
    func configureLanguage(credentials: any CredentialStoring, settings: @escaping () -> AppSettings) {
        coordinator.understand = { input in
            let config = settings().main
            guard let key = try await credentials.readWithoutInteraction(.main) else { throw SettingsError.missingKey }
            let brief = try await TaskUnderstandingService().understand(input, configuration: config, key: key)
            guard settings().main == config else { throw CancellationError() }
            return brief
        }
        coordinator.routeIntent = { input, previous, allowNote in
            let appSettings = settings(), resolved = appSettings.resolvedConfiguration(for: .auxiliary)
            let config = resolved.credentialSlot == .main ? resolved.configuration : appSettings.main
            guard let key = try? await credentials.readWithoutInteraction(.main) else { return .chat }
            return await IntentRouter().route(input, previous: previous, allowNote: allowNote, configuration: config, key: key)
        }
        coordinator.executionModel = { context in
            let config = await MainActor.run { settings().main }
            guard let key = try await credentials.readWithoutInteraction(.main) else { throw SettingsError.missingKey }
            let result = try await TaskExecutionService().next(context, configuration: config, key: key)
            guard await MainActor.run(body: { settings().main == config }) else { throw CancellationError() }
            return result
        }
        coordinator.supervisionModel = { context in
            let config = await MainActor.run { settings().main }
            guard let key = try await credentials.readWithoutInteraction(.main) else { throw SettingsError.missingKey }
            let result = try await AgentSupervisor.evaluate(context, configuration: config, key: key)
            guard await MainActor.run(body: { settings().main == config }) else { throw CancellationError() }
            return result
        }
    }
    private func updated(_ task: AssistantTask) {
        if task.status == .waitingUser, task.scope != nil {
            Task { [weak self] in
                guard let self else { return }
                let question = try? await self.coordinator.executionDetails(task.id).question
                guard self.coordinator.tasks.contains(where: { $0.id == task.id && $0.status == .waitingUser && $0.updatedAt == task.updatedAt }) else { return }
                self.presentUpdated(task, question: question)
            }
        } else { presentUpdated(task) }
    }
    private func presentUpdated(_ task: AssistantTask, question: AssistantRuntimeQuestion? = nil) {
        island.resolve(eventIDs.removeValue(forKey: task.id) ?? [])
        guard !paused else { return }
        let text: String
        let action: IslandAction
        switch task.status {
        case .understanding: text = "正在理解"; action = .init("task", "查看任务")
        case .needsInfo: text = "有几件事想确认"; action = .init("task", "回答")
        case .planReady: text = "计划准备好了"; action = .init("task", "看计划")
        case .scheduled: text = "已设好：" + (task.plan?.reminders.first.map(AssistantDates.text) ?? "提醒"); action = .init("undoReminder", "撤销")
        case .failed: text = task.scope == nil ? "没能理解，可以重试或改写" : "没做成，已有结果保留"; action = .init("task", "查看")
        case .completed: text = "结果写好了"; action = .init("task", "查看结果")
        case .waitingUser:
            text = task.errorCode == "modelNotConfigured" ? "先配置模型，助手才能理解任务" : question?.text.components(separatedBy: "\n").first ?? "有件事需要你决定"
            action = task.errorCode == "modelNotConfigured" ? .init("settings", "去设置") : .init("task", "查看并处理")
        case .interrupted: text = "任务已中断，进度保留"; action = .init("task", "继续或结束")
        default: return
        }
        let id = UUID(); eventIDs[task.id, default: []].insert(id)
        let approval = question?.kind == "approval"
        if approval { approvalQuestions[id] = question?.id }
        let actions: [IslandAction] = approval ? [.init("declineAgent", "不允许"), .init("approveOnce", "允许这一次"), .init("task", "查看详情")] : [action]
        island.receive(.init(id: id, taskID: task.id, priority: task.status.group == .attention ? .blocker : task.status == .failed ? .failed : task.status == .completed ? .completed : .received,
            tone: task.status == .failed ? .red : task.status == .completed ? .green : task.status.group == .attention ? .orange : .blue,
            compactText: text, title: task.title, body: task.status == .scheduled ? text + "\n助手只在萌生运行时工作。退出或关机后不会提醒。" : question?.text ?? task.resultSummary ?? text, actions: actions,
            policy: task.status.group == .attention ? .blocker : .completed))
    }
    private func showReminders(_ values: [AssistantReminder], missed: Bool) {
        let id = UUID(); reminderEvents[id] = values.map(\.id); reminderContents[id] = (values, missed)
        let text = missed ? "你不在时错过了 \(values.count) 个提醒" : values.count == 1 ? values[0].title : "\(values.count) 件事到提醒时间了"
        island.receive(.init(id: id, taskID: values.count == 1 ? values[0].taskID : nil, priority: .reminder, tone: .blue,
            compactText: text, title: text, body: values.map { $0.title + " · " + AssistantDates.text($0.fireAt) }.joined(separator: "\n"),
            actions: [.init("snooze", "晚点再说"), .init("ack", "知道了")], policy: .reminder))
    }
    private func received(_ task: AssistantTask) {
        guard !paused else { return }
        ApplicationExtensionHost.shared.module?.captureFeedback(.received)
        guard !panelVisible() else { return }
        let missing = task.errorCode == "modelNotConfigured"
        let eventID = UUID()
        eventIDs[task.id, default: []].insert(eventID)
        island.receive(.init(id: eventID, taskID: task.id, priority: missing ? .blocker : .received,
                             tone: missing ? .orange : .blue,
                             compactText: missing ? "先配置模型，助手才能理解任务" : "收到了，已保存",
                             title: task.title, body: missing ? "交办内容已保存，先配置模型服务。" : "交办内容已保存，尚未开始执行。",
                             actions: missing ? [.init("settings", "去设置")] : [.init("task", "查看任务")],
                             policy: missing ? .blocker : .received))
    }
    private func receiveDrop(_ input: String, attachments: [AssistantAttachment], id: String) {
        guard dropWrites[id] == nil else { return }
        dropWrites[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.dropWrites[id] = nil }
            do {
                try await self.coordinator.receive(input: input, source: attachments.isEmpty ? .notchText : .notchFiles,
                                                   attachments: attachments, id: id)
                self.failedDrops[id] = nil
            } catch {
                if self.failedDrops.count < 16 { self.failedDrops[id] = (input, attachments) }
                self.viewModel.feedback = "任务未能保存，原内容未修改。请重试。"
                self.island.receive(.init(taskID: id, priority: .failed, tone: .red, compactText: "任务未能保存，请重试",
                                         title: "任务未能保存", body: "原内容未修改。", actions: [.init("retry", "重试")], policy: .failed))
            }
        }
    }
    func refreshPending() { onPendingChanged(taskNeedsAttention || island.needsIndicator) }
    func refreshPresentation() { island.gate.refresh() }
    func pauseAndDrain() async {
        paused = true; drop.cancel(); await menuDrop.drain()
        await startup?.value
        for write in Array(dropWrites.values) { await write.value }
        await coordinator.pauseAndDrain()
    }
    func resume() { paused = false; coordinator.resume() }
    func stop() {
        paused = true; startup?.cancel(); coordinator.reminders.stop(); drop.stop(); menuDrop.stop(); island.stop()
        for token in observers { NotificationCenter.default.removeObserver(token); NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers.removeAll()
    }
}
