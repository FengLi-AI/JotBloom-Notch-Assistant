import AppKit
import Combine
import JotBloomCore

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var value: AppSettings
    @Published var feedback: String?
    @Published var systemPromptDraft: String = ""
    var hasUnsavedSystemPrompt: Bool { systemPromptDraft != value.chatSystemPrompt }
    func allowLeavingPrompt() -> Bool {
        if hasUnsavedSystemPrompt { feedback = "系统提示词尚未保存，请先保存修改或放弃修改。"; return false }
        return true
    }
    func saveSystemPrompt() {
        let text = systemPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000 else { feedback = "系统提示词请输入 1–2000 个字符。"; return }
        value.chatSystemPrompt = text; systemPromptDraft = text; persist()
        feedback = "已保存，新会话生效；现有会话保持原设置。"
    }
    func restoreDefaultSystemPrompt() { systemPromptDraft = ChatContext.system; feedback = "已填入默认内容，点击保存修改后生效。" }
    func discardSystemPrompt() { systemPromptDraft = value.chatSystemPrompt; feedback = "已放弃未保存的修改。" }
    func setInspirationAI(_ enabled: Bool) {
        value.inspirationAIEnabled = enabled; persist(); onAIConfigurationChanged?()
        feedback = enabled ? "已开启。仅处理之后新保存的灵感，不上传历史记录。" : "已关闭灵感 AI 整理，本地保存不受影响。"
    }
    @Published private(set) var busy = false
    @Published private(set) var maintaining = false
    @Published private(set) var migrating = false
    @Published private(set) var choosingDirectory = false
    var blocksPanelInteraction: Bool { maintaining || choosingDirectory || confirmingClear }
    @Published var recordingShortcut = false
    @Published var showingOnboarding = false
    @Published var onboardingStep = 0
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginStatus = ""
    @Published private(set) var usage: ClipboardUsage?
    @Published private(set) var dataDirectory: URL
    @Published var mainURL: String
    @Published var mainModel: String
    @Published var auxiliaryURL: String
    @Published var auxiliaryModel: String
    @Published var keyInputs: [ModelSlot: String] = [:]
    @Published private(set) var keyMasks: [ModelSlot: String] = [:]
    @Published private(set) var connectionStatus: [ModelSlot: String] = [:]
    @Published private(set) var testing: Set<ModelSlot> = []
    @Published private(set) var readingCredential = false
    @Published private(set) var credentialHelp: Set<ModelSlot> = []
    private var recoveryTask: Task<Void, Never>?
    private let persistence: AppSettingsStore
    private let credentials: any CredentialStoring
    private let login: any LoginItemServicing
    private let tester: ConnectionTester
    private var connectionTasks: [ModelSlot: Task<Void, Never>] = [:]
    private var revision = 0
    private var systemObserver: NSObjectProtocol?
    private var migrationTask: Task<URL, Error>?
    var onMonitoring: ((Bool) async throws -> Void)?
    var onRetention: ((ClipboardRetentionPolicy) async throws -> Void)?
    var onClear: (([ClipboardItem]) async throws -> Bool)?
    var onClearSnapshot: (() async throws -> [ClipboardItem])?
    @Published private(set) var clearSnapshot: [ClipboardItem] = []
    @Published var confirmingClear = false
    var onRetryCleanup: (() async throws -> Void)?
    var onUsage: (() async throws -> ClipboardUsage)?
    var onMigrate: ((URL, @escaping @Sendable (String) -> Void) async throws -> URL)?
    var onShortcut: ((Shortcut) -> Bool)?
    var onMenuVisibility: ((Bool) -> Bool)?
    var onSystemInteraction: ((Bool) -> Void)?
    var onDirectorySelection: ((Bool) -> Void)?
    var onAIConfigurationChanged: (() -> Void)?
    var onMainAIConfigurationChanged: (() -> Void)?

    init(persistence: AppSettingsStore, credentials: any CredentialStoring, login: any LoginItemServicing,
         dataDirectory: URL, tester: ConnectionTester = ConnectionTester()) {
        self.persistence = persistence; self.credentials = credentials; self.login = login
        self.dataDirectory = dataDirectory; self.tester = tester
        let value = persistence.load(); self.value = value
        systemPromptDraft = value.chatSystemPrompt
        mainURL = value.main.baseURL; mainModel = value.main.model
        auxiliaryURL = value.auxiliary.baseURL; auxiliaryModel = value.auxiliary.model
        refreshLogin()
        systemObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshLogin() }
        }
    }
    deinit {
        recoveryTask?.cancel()
        if let systemObserver { NSWorkspace.shared.notificationCenter.removeObserver(systemObserver) }
        for task in connectionTasks.values { task.cancel() }
    }
    private func persist() { persistence.save(value) }
    func refreshLogin() { loginEnabled = login.enabled; loginStatus = login.statusText }
    func setLogin(_ enabled: Bool) {
        run { [self] in
            defer { refreshLogin() }
            try await login.setEnabled(enabled)
        }
    }
    func setMenuVisible(_ visible: Bool) {
        guard !busy else { return }
        guard onMenuVisibility?(visible) == true else { feedback = "唤起快捷键不可用，暂时不能隐藏菜单栏入口。"; return }
        value.showMenuBarIcon = visible; persist()
        feedback = visible ? "菜单栏入口已显示。" : "菜单栏入口已隐藏，可用 \(value.shortcut.label) 呼出后进入设置。"
    }
    func restoreMenuPreference() { value.showMenuBarIcon = true; persist() }
    func setShortcut(_ shortcut: Shortcut) {
        guard !busy else { return }
        recordingShortcut = false
        guard shortcut.isValid else { feedback = SettingsError.invalidShortcut.localizedDescription; return }
        guard onShortcut?(shortcut) == true else { feedback = "这个快捷键无法注册，原快捷键仍保留。"; return }
        value.shortcut = shortcut; persist(); feedback = "唤起快捷键已改为 \(shortcut.label)"
    }
    func setMonitoring(_ enabled: Bool) {
        run { [self] in
            guard let onMonitoring else { throw SettingsError.maintenance }
            try await onMonitoring(enabled)
            value.monitoringEnabled = enabled; persist()
            feedback = enabled ? "监听已开启，只记录接下来新复制的内容。" : "监听已暂停，已有历史不受影响。"
        }
    }
    func setRetention(count: Int? = nil, days: Int? = nil, bytes: Int64? = nil) {
        var candidate = value
        if let count, AppSettings.countOptions.contains(count) { candidate.maximumCount = count }
        if let days, AppSettings.dayOptions.contains(days) { candidate.maximumDays = days }
        if let bytes, AppSettings.byteOptions.contains(bytes) { candidate.maximumBytes = bytes }
        run { [self] in
            guard let onRetention else { throw SettingsError.maintenance }
            // The new policy is authoritative even if cleanup fails. Expose retry, never show the old limit as active.
            value = candidate; persist()
            try await onRetention(candidate.retentionPolicy)
            await refreshUsage(); feedback = "保留规则已生效，超限历史已清理。"
        }
    }
    func refreshUsage() async {
        do { usage = try await onUsage?() } catch { feedback = "暂时无法读取磁盘用量，请重试。" }
    }
    func prepareClearHistory() {
        run { [self] in
            guard let onClearSnapshot else { throw SettingsError.maintenance }
            clearSnapshot = try await onClearSnapshot()
            confirmingClear = true
        }
    }
    var clearConfirmationMessage: String {
        "将清除本次确认范围内的 \(clearSnapshot.count) 条历史及其图片，不可撤销。之后新增或重新采集的记录保留。已另存的灵感、提示词、草稿及系统当前剪贴板不受影响；监听开关保持不变。"
    }
    func clearHistory() {
        let snapshot = clearSnapshot
        run(maintenance: true) { [self] in
            guard let onClear else { throw SettingsError.maintenance }
            let complete = try await onClear(snapshot)
            await refreshUsage()
            feedback = complete ? "已清理确认范围内未变化的历史；灵感、提示词和监听设置不变。" : "记录已清理，部分图片清理失败，可重试文件清理。"
        }
    }
    func retryCleanup() {
        run { [self] in
            guard let onRetryCleanup else { throw SettingsError.maintenance }
            try await onRetryCleanup(); await refreshUsage(); feedback = "文件清理已完成。"
        }
    }
    func migrate(to parent: URL) {
        run(maintenance: true) { [self] in
            guard let onMigrate else { throw SettingsError.maintenance }
            migrating = true
            let task = Task { try await onMigrate(parent) { [weak self] message in Task { @MainActor in self?.feedback = message } } }
            migrationTask = task
            defer { migrationTask = nil; migrating = false }
            dataDirectory = try await task.value
            feedback = "保存位置已切换；旧位置保留迁移前副本，新内容仅写新位置。"
        }
    }
    func cancelMigration() { migrationTask?.cancel() }
    @discardableResult
    func beginDirectorySelection() -> Bool {
        guard !busy, !choosingDirectory else { return false }
        choosingDirectory = true
        onSystemInteraction?(true)
        onDirectorySelection?(true)
        return true
    }
    func endDirectorySelection() {
        guard choosingDirectory else { return }
        choosingDirectory = false
        onDirectorySelection?(false)
        onSystemInteraction?(false)
    }
    func reopenOnboarding() { onboardingStep = 0; showingOnboarding = true }
    func finishOnboarding() { value.onboardingSeen = true; persist(); showingOnboarding = false }
    func markExistingUser() { value.onboardingSeen = true; persist() }

    func configurationEdited() {
        if mainURL != value.main.baseURL || mainModel != value.main.model { onMainAIConfigurationChanged?() }
        onAIConfigurationChanged?(); cancelTests(); connectionStatus.removeAll()
    }
    func previewConfiguration(for slot: ModelSlot) -> (configuration: ModelConfiguration, credentialSlot: ModelSlot) {
        var preview = value
        preview.main = ModelConfiguration(baseURL: mainURL, model: mainModel)
        preview.auxiliary = ModelConfiguration(baseURL: auxiliaryURL, model: auxiliaryModel)
        return preview.resolvedConfiguration(for: slot)
    }
    func setAuxiliaryUsesMain(_ shared: Bool) {
        guard !busy else { return }
        value.auxiliaryUsesMain = shared; persist(); configurationEdited()
    }
    @discardableResult
    func commitModelEdits() -> Bool {
        do {
            let previousMain = value.main, previousAuxiliary = value.auxiliary
            let normalizedMain = mainURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try ModelEndpoint.normalize(mainURL)
            let normalizedAux = auxiliaryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try ModelEndpoint.normalize(auxiliaryURL)
            value.main = ModelConfiguration(baseURL: normalizedMain, model: mainModel.trimmingCharacters(in: .whitespacesAndNewlines))
            value.auxiliary = ModelConfiguration(baseURL: normalizedAux, model: auxiliaryModel.trimmingCharacters(in: .whitespacesAndNewlines))
            mainURL = value.main.baseURL; mainModel = value.main.model
            auxiliaryURL = value.auxiliary.baseURL; auxiliaryModel = value.auxiliary.model
            if previousMain != value.main || previousAuxiliary != value.auxiliary { onAIConfigurationChanged?() }
            if previousMain != value.main { onMainAIConfigurationChanged?() }
            persist(); return true
        } catch { feedback = error.localizedDescription; return false }
    }
    // This is only session-local display information, never a reason to read Keychain.
    // On launch an existing key is unknown, not absent. Read only on explicit use.
    func keyDisplayStatus(_ slot: ModelSlot) -> String {
        keyMasks[slot] ?? "未读取（使用时检查）"
    }
    func saveKey(_ slot: ModelSlot) {
        guard !readingCredential, testing.isEmpty, let secret = keyInputs[slot], !secret.isEmpty else { return }
        run { [self] in
            onAIConfigurationChanged?()
            try await credentials.write(secret, slot: slot)
            if slot == .main { onMainAIConfigurationChanged?() }
            keyMasks[slot] = ModelEndpoint.maskedKey(secret)
            keyInputs[slot] = ""; configurationEdited(); feedback = "密钥已保存到系统钥匙串。"
        }
    }
    func removeKey(_ slot: ModelSlot) {
        guard !readingCredential, testing.isEmpty else { return }
        run { [self] in
            onAIConfigurationChanged?()
            try await credentials.remove(slot)
            if slot == .main { onMainAIConfigurationChanged?() }
            keyInputs[slot] = ""; keyMasks[slot] = "未配置"; configurationEdited(); feedback = "密钥已移除，本地功能仍可用。"
        }
    }
    // Never called by connection testing, navigation or model requests.
    func recoverKeyAccess(_ slot: ModelSlot) {
        guard !busy, !readingCredential, testing.isEmpty, commitModelEdits() else { return }
        let credentialSlot = value.resolvedConfiguration(for: slot).credentialSlot
        let expected = revision
        busy = true; readingCredential = true
        feedback = "正在处理旧密钥访问；此操作不会调用模型。"
        let protection = onSystemInteraction
        protection?(true)
        recoveryTask = Task { [weak self] in
            defer {
                self?.busy = false; self?.readingCredential = false; self?.recoveryTask = nil
                protection?(false)
            }
            do {
                guard let self else { return }
                let key = try await credentials.authorize(credentialSlot)
                try Task.checkCancellation()
                guard revision == expected else { return }
                guard let key else { throw SettingsError.missingKey }
                keyMasks[credentialSlot] = ModelEndpoint.maskedKey(key)
                credentialHelp.remove(slot)
                feedback = "密钥访问已恢复。请主动测试连接或返回对话重新发送，本次未调用模型。"
                connectionStatus[slot] = "密钥访问已恢复，尚未测试连接。"
            } catch {
                guard let self, !Task.isCancelled, revision == expected else { return }
                credentialHelp.insert(slot)
                feedback = (error as? SettingsError)?.localizedDescription ?? "密钥访问未恢复，原有配置保留。"
            }
        }
    }
    func testConnection(_ slot: ModelSlot) {
        guard !busy, !readingCredential, testing.isEmpty, commitModelEdits() else { return }
        let effective = value.resolvedConfiguration(for: slot)
        // Reject incomplete configuration before asking the system for credentials.
        do {
            _ = try ModelEndpoint.normalize(effective.configuration.baseURL)
            guard !effective.configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SettingsError.missingModel }
        } catch {
            connectionStatus[slot] = error.localizedDescription
            return
        }
        let expected = revision
        testing.insert(slot); connectionStatus[slot] = "正在测试…"
        // Authorization and the ensuing network request form one protected UI operation.
        // Hold the guard until the result/error is published, not only until Keychain returns.
        let systemInteraction = onSystemInteraction
        systemInteraction?(true)
        connectionTasks[slot] = Task { [weak self, tester] in
            defer { systemInteraction?(false) }
            do {
                guard let self else { return }
                let key = try await readTestCredential(effective.credentialSlot)
                guard let key else { throw SettingsError.missingKey }
                let result = try await tester.test(configuration: effective.configuration, key: key)
                guard revision == expected, !Task.isCancelled else { return }
                connectionStatus[slot] = "连接成功 · \(Int(result.elapsedMilliseconds))ms · \(result.attempts) 次请求"
                    + (result.totalTokens.map { " · \($0) tokens" } ?? " · 服务未提供用量")
                credentialHelp.remove(slot)
            } catch {
                guard let self, revision == expected, !Task.isCancelled else { return }
                connectionStatus[slot] = (error as? SettingsError)?.localizedDescription ?? "连接失败，请检查配置。"
                if let error = error as? SettingsError, error.isCredentialIssue { credentialHelp.insert(slot) }
            }
            self?.testing.remove(slot); self?.connectionTasks.removeValue(forKey: slot)
        }
    }
    func cancelTests() {
        revision += 1
        if let recoveryTask { recoveryTask.cancel(); feedback = "已取消恢复，原有密钥保持不变。" }
        for task in connectionTasks.values { task.cancel() }
        for slot in testing { connectionStatus[slot] = "测试已取消" }
        connectionTasks.removeAll(); testing.removeAll()
    }
    private func readTestCredential(_ slot: ModelSlot) async throws -> String? {
        try Task.checkCancellation()
        readingCredential = true
        onSystemInteraction?(true)
        defer { readingCredential = false; onSystemInteraction?(false) }
        let key = try await credentials.readWithoutInteraction(slot)
        // A Keychain system dialog may outlive cancellation or leaving this page.
        // Its late result must not update the UI or start a network request.
        try Task.checkCancellation()
        keyMasks[slot] = key.map(ModelEndpoint.maskedKey) ?? "未配置"
        return key
    }
    func leaveSettings() {
        cancelTests(); keyInputs.removeAll(); recordingShortcut = false
        _ = commitModelEdits()
    }
    private func run(maintenance: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; maintaining = maintenance; feedback = nil
        onSystemInteraction?(true)
        Task { [self] in
            defer { busy = false; maintaining = false; onSystemInteraction?(false) }
            do { try await action() }
            catch is CancellationError { feedback = "操作已取消，原数据保留。" }
            catch { feedback = (error as? LocalizedError)?.errorDescription ?? "操作未完成，请检查磁盘、权限或系统状态后重试。" }
        }
    }
}
