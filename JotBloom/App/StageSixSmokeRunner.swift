#if DEBUG
import AppKit
import Darwin
import JotBloomCore

private actor SettingsSmokeCredentials: CredentialStoring {
    private var keys: [ModelSlot: String] = [:]
    var denyWrites = false
    private(set) var readSlots: [ModelSlot] = []
    private var readFailure: SettingsError?
    private var readDelay: Double = 0
    func setDenyWrites(_ value: Bool) { denyWrites = value }
    func setReadFailure(_ value: SettingsError?) { readFailure = value }
    func setReadDelay(_ value: Double) { readDelay = value }
    func stored(_ slot: ModelSlot) -> String? { keys[slot] }
    // Exercise delayed silent access and failure handling, not automatic UI fallback.
    func readWithoutInteraction(_ slot: ModelSlot) async throws -> String? { try await read(slot) }
    func read(_ slot: ModelSlot) async throws -> String? {
        readSlots.append(slot)
        if readDelay > 0 {
            // Model a system authorization dialog that cannot be cancelled by Task.cancel().
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + readDelay) { continuation.resume() }
            }
        }
        if let readFailure { throw readFailure }
        return keys[slot]
    }
    func write(_ secret: String, slot: ModelSlot) throws {
        if denyWrites { throw SettingsError.credentialDenied }; keys[slot] = secret
    }
    func remove(_ slot: ModelSlot) { keys.removeValue(forKey: slot) }
}
private actor SettingsSmokeTransport: ConnectionTransport {
    var calls = 0
    private var delay: UInt64 = 60_000_000
    func setDelay(_ value: UInt64) { delay = value }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        try await Task.sleep(nanoseconds: delay)
        return (Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8), 200)
    }
}
@MainActor
enum StageSixSmokeRunner {
    static func run() async {
        var checks: [(String, Bool)] = []
        let root = DataDirectoryResolver.makeEphemeralDirectory(prefix: "jotbloom-stage6-smoke")
        let suite = "JotBloom.Stage6." + UUID().uuidString
        let named = NSPasteboard(name: .init("JotBloom.Stage6." + UUID().uuidString))
        let generalBefore = NSPasteboard.general.changeCount
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("jotbloom-stage6-ui-" + UUID().uuidString)
        var failure = false
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let defaults = UserDefaults(suiteName: suite)!
            let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
            let exceptions = ats?["NSExceptionDomains"] as? [String: [String: Any]]
            checks.append(("ats_exact_loopback_only", ats?["NSAllowsArbitraryLoads"] == nil && Set(exceptions?.keys.map { $0 } ?? []) == Set(["localhost", "127.0.0.1", "::1"]) && exceptions?.values.allSatisfy { $0["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true && $0["NSIncludesSubdomains"] as? Bool == false } == true))
            let production = try DataDirectoryResolver.productionDirectory()
            let productionBefore = DebugDirectorySnapshot.capture(url: production)
            let credentials = SettingsSmokeCredentials(), transport = SettingsSmokeTransport()
            let store = try JotBloomStore(dataDirectoryURL: root)
            defer { store.close() }
            let assets = try ClipboardAssetStore(dataDirectoryURL: root)
            let gate = CapturePermission()
            let service = ClipboardService(store: store, assetStore: assets, capturePermission: gate)
            let client = SystemPasteboardClient(pasteboard: named)
            let clipboard = ClipboardHistoryViewModel(service: service, pasteboardWriter: client)
            let captures = ClipboardCaptureCoordinator(service: service, viewModel: clipboard)
            let notifications = NotificationCenter()
            let monitor = PasteboardMonitor(pasteboard: client, workspaceNotificationCenter: notifications,
                sourceProvider: { .init(name: "Stage6 fixture", bundleIdentifier: "test.fixture") }, onSnapshot: captures.enqueue)
            defer { monitor.stop() }
            let model = SettingsViewModel(persistence: .init(defaults: defaults), credentials: credentials, login: IsolatedLoginItemService(), dataDirectory: root, tester: .init(transport: transport))
            model.onShortcut = { _ in false }; model.setShortcut(.init(keyCode: 40, modifiers: 2048, label: "⌥K"))
            checks.append(("shortcut_failure_preserves_old", model.value.shortcut == .standard))
            model.onShortcut = { _ in true }; model.setShortcut(.init(keyCode: 40, modifiers: 2048, label: "⌥K"))
            checks.append(("shortcut_success_persists", AppSettingsStore(defaults: defaults).load().shortcut.keyCode == 40))
            model.onMenuVisibility = { _ in false }; model.setMenuVisible(false)
            checks.append(("menu_rescue_guard", model.value.showMenuBarIcon))
            model.setLogin(true); try await settle(model)
            checks.append(("fake_login_enabled", model.loginEnabled))
            model.setLogin(false); try await settle(model)
            checks.append(("fake_login_disabled", !model.loginEnabled))
            model.reopenOnboarding(); model.finishOnboarding()
            checks.append(("onboarding_skip_persisted", AppSettingsStore(defaults: defaults).load().onboardingSeen && !model.showingOnboarding))
            model.keyInputs[.main] = "fixture-secret-1234"; model.saveKey(.main); try await settle(model)
            checks.append(("key_mask_and_empty_buffer", model.keyMasks[.main] == "••••1234" && model.keyInputs[.main] == ""))
            await credentials.setDenyWrites(true)
            model.keyInputs[.main] = "fixture-replacement"; model.saveKey(.main); try await settle(model)
            let preserved = try await credentials.read(.main)
            checks.append(("key_failure_preserves_old", preserved == "fixture-secret-1234" && model.keyInputs[.main] == "fixture-replacement"))
            model.keyInputs[.main] = ""; model.saveKey(.main)
            let unchanged = try await credentials.read(.main)
            checks.append(("empty_key_buffer_not_delete", unchanged == preserved))
            await credentials.setDenyWrites(false)
            model.mainURL = "https://fixture.invalid/v1"; model.mainModel = "fixture-model"
            model.testConnection(.main)
            try await Task.sleep(nanoseconds: 120_000_000)
            checks.append(("fake_connection_success", model.connectionStatus[.main]?.hasPrefix("连接成功") == true))
            model.testConnection(.main); model.configurationEdited()
            try await Task.sleep(nanoseconds: 100_000_000)
            checks.append(("stale_connection_cancelled", model.testing.isEmpty && model.connectionStatus.isEmpty))
            model.mainURL = "http://unsafe.invalid"; checks.append(("invalid_edit_preserves_config", !model.commitModelEdits() && model.value.main.baseURL == "https://fixture.invalid/v1"))
            model.mainURL = model.value.main.baseURL
            model.removeKey(.main); try await settle(model)
            let removed = try await credentials.read(.main)
            checks.append(("exact_key_removal", removed == nil))
            let serialized = String(describing: defaults.dictionaryRepresentation())
            checks.append(("no_secret_in_preferences", !serialized.contains("fixture-secret") && !serialized.contains("fixture-replacement")))
            checks.append(contentsOf: try await credentialAccessChecks(root: root))
            monitor.start()
            try client.writeText("first"); monitor.pollNow()
            await captures.stopAndDrain(); captures.resume()
            // Queued but uncommitted snapshots are invalidated synchronously by stopAndDrain.
            checks.append(("queued_capture_invalidated", try store.listClipboardItemsSynchronously().isEmpty))
            monitor.setUserEnabled(false)
            try client.writeText("disabled")
            notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
            notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await Task.sleep(nanoseconds: 30_000_000)
            monitor.pollNow(); monitor.setUserEnabled(true); monitor.pollNow()
            checks.append(("disabled_wake_no_backfill", try store.listClipboardItemsSynchronously().isEmpty))
            notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
            notifications.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await Task.sleep(nanoseconds: 30_000_000)
            checks.append(("pause_reasons_independent", monitor.debugIsPaused))
            notifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            try await Task.sleep(nanoseconds: 30_000_000)
            try client.writeText("enabled-new"); monitor.pollNow()
            try await Task.sleep(nanoseconds: 50_000_000)
            checks.append(("reenabled_new_capture", try store.listClipboardItemsSynchronously().first?.textContent == "enabled-new"))
            gate.setAllowed(false); monitor.setMaintenancePaused(true); await captures.stopAndDrain()
            let cleared = try await service.clearHistory()
            captures.resume(); gate.setAllowed(true); monitor.setMaintenancePaused(false); monitor.pollNow()
            let emptyAfterClear = try store.listClipboardItemsSynchronously().isEmpty
            checks.append(("clear_no_refill", cleared && emptyAfterClear))
            // Fresh model represents an app restart: old keys must remain unknown, not absent.
            let reopenedModel = SettingsViewModel(persistence: .init(defaults: defaults), credentials: credentials, login: IsolatedLoginItemService(), dataDirectory: root, tester: .init(transport: transport))
            reopenedModel.onUsage = { try await service.usage() }
            let readsBeforePages = await credentials.readSlots.count
            await credentials.setReadFailure(.credentialDenied)
            let input = InspirationInputViewModel(store: store)
            let library = InspirationLibraryViewModel(store: store)
            let search = GlobalSearchViewModel(store: store, pasteboardWriter: client)
            input.start(); library.start(); clipboard.start()
            let panel = PanelController(inspirationViewModel: input, clipboardViewModel: clipboard, inspirationLibraryViewModel: library, globalSearchViewModel: search, dataDirectory: root, settingsModel: reopenedModel)
            checks.append(("inline_settings_five_sections_and_escape", try await panel.debugSettingsProbe(output: output)))
            checks.append(contentsOf: try await panel.debugSettingsFixesProbe(output: output))
            let readsAfterPages = await credentials.readSlots.count
            checks.append(("ai_page_reentry_zero_credential_reads", readsBeforePages == readsAfterPages))
            checks.append(("unread_not_mislabelled_missing", reopenedModel.keyMasks.isEmpty && reopenedModel.keyDisplayStatus(.main) == "未读取（使用时检查）"))
            await credentials.setReadFailure(nil)
            try await credentials.write("fixture-focus-5678", slot: .main)
            await credentials.setReadDelay(0.15)
            await transport.setDelay(200_000_000)
            checks.append(contentsOf: try await panel.debugAuthorizationFocusProbe { reopenedModel.testConnection(.main) })
            panel.close(); reopenedModel.leaveSettings(); model.leaveSettings()
            try await input.prepareForTermination(); _ = await library.prepareForTermination(); await clipboard.prepareForTermination()
            await captures.stopAndDrain()
            checks.append(("general_pasteboard_untouched", NSPasteboard.general.changeCount == generalBefore))
            checks.append(("production_metadata_untouched", DebugDirectorySnapshot.capture(url: production) == productionBefore))
        } catch { failure = true; print("JOTBLOOM_STAGE6_SMOKE error_type=\(String(describing: type(of: error)))") }
        named.releaseGlobally(); UserDefaults.standard.removePersistentDomain(forName: suite)
        // Exact owned UUID directory only; screenshots deliberately remain as inspectable evidence.
        if root.lastPathComponent.hasPrefix("jotbloom-stage6-smoke-"), root.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path) { try? FileManager.default.removeItem(at: root) }
        for (name, passed) in checks { print("JOTBLOOM_STAGE6_CHECK \(name)=\(passed)") }
        print("JOTBLOOM_STAGE6_SCREENSHOTS \(output.path)")
        let passed = !failure && !checks.isEmpty && checks.allSatisfy(\.1)
        print("JOTBLOOM_STAGE6_SMOKE success=\(passed) checks=\(checks.count) real_api_tested=false real_login_tested=false real_keychain_tested=false")
        fflush(stdout); exit(passed ? 0 : 1)
    }
    private static func credentialAccessChecks(root: URL) async throws -> [(String, Bool)] {
        let suite = "JotBloom.CredentialAccess." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = SettingsSmokeCredentials(), transport = SettingsSmokeTransport()
        let model = SettingsViewModel(persistence: .init(defaults: defaults), credentials: credentials, login: IsolatedLoginItemService(), dataDirectory: root, tester: .init(transport: transport))
        var checks: [(String, Bool)] = []
        let initialReads = await credentials.readSlots
        checks.append(("settings_init_zero_credential_reads", initialReads.isEmpty))
        model.testConnection(.main)
        model.mainURL = "https://fixture.invalid/v1"; model.testConnection(.main)
        let invalidReads = await credentials.readSlots
        checks.append(("incomplete_config_no_authorization", invalidReads.isEmpty && model.testing.isEmpty))
        try await credentials.write("fixture-main-5678", slot: .main)
        try await credentials.write("fixture-aux-9012", slot: .auxiliary)
        model.mainModel = "main"; model.auxiliaryModel = "aux"
        model.testConnection(.main); try await settleConnection(model)
        let mainReads = await credentials.readSlots
        checks.append(("explicit_main_reads_only_main", mainReads == [.main] && model.keyMasks[.main] == "••••5678"))
        model.testConnection(.auxiliary); try await settleConnection(model)
        let sharedReads = await credentials.readSlots
        checks.append(("explicit_aux_shared_reads_only_main", sharedReads == [.main, .main]))
        model.setAuxiliaryUsesMain(false); model.auxiliaryURL = "https://aux.fixture.invalid/v1"
        model.testConnection(.auxiliary); try await settleConnection(model)
        let separateReads = await credentials.readSlots
        checks.append(("explicit_aux_independent_reads_aux", separateReads == [.main, .main, .auxiliary] && model.keyMasks[.auxiliary] == "••••9012"))
        for failure in [SettingsError.credentialDenied, .credentialLocked, .credentialCancelled] {
            await credentials.setReadFailure(failure)
            let requestsBefore = await transport.calls
            let readsBefore = await credentials.readSlots.count
            model.testConnection(.main); try await settleConnection(model)
            let requestsAfter = await transport.calls
            let readsAfter = await credentials.readSlots.count
            let retained = await credentials.stored(.main)
            checks.append(("credential_\(String(describing: failure))_no_retry_no_network", requestsBefore == requestsAfter && readsAfter == readsBefore + 1 && retained == "fixture-main-5678" && model.connectionStatus[.main] == failure.localizedDescription))
        }
        await credentials.setReadFailure(nil)
        model.testConnection(.main); try await settleConnection(model)
        checks.append(("explicit_retry_after_denial_succeeds", model.connectionStatus[.main]?.hasPrefix("连接成功") == true))
        await credentials.setReadDelay(0.12)
        let requestsBeforeCancel = await transport.calls
        let readsBeforeCancel = await credentials.readSlots.count
        model.testConnection(.main)
        for _ in 0..<100 {
            if model.readingCredential { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        model.leaveSettings()
        model.testConnection(.auxiliary)
        try await settleConnection(model)
        let requestsAfterCancel = await transport.calls
        let readsAfterCancel = await credentials.readSlots.count
        checks.append(("cancel_pending_auth_discards_result_no_parallel_prompt", requestsBeforeCancel == requestsAfterCancel && readsAfterCancel == readsBeforeCancel + 1 && model.testing.isEmpty && !model.readingCredential))
        let preferences = String(describing: defaults.dictionaryRepresentation())
        checks.append(("no_key_or_mask_persisted", !preferences.contains("fixture-main-5678") && !preferences.contains("fixture-aux-9012") && !preferences.contains("••••")))
        return checks
    }
    private static func settleConnection(_ model: SettingsViewModel) async throws {
        for _ in 0..<300 {
            if model.testing.isEmpty && !model.readingCredential { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw SettingsError.timeout
    }
    private static func settle(_ model: SettingsViewModel) async throws {
        for _ in 0..<200 { if !model.busy { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw SettingsError.timeout
    }
}
#endif
