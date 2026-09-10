#if DEBUG
import AppKit
import Security
import Darwin
import JotBloomCore

private actor TenCredentials: CredentialStoring {
    var authorized: Set<ModelSlot> = [], denied = false, calls = 0
    var lastAuthorizedSlot: ModelSlot?
    func revoke() { authorized.removeAll(); denied = true }
    func resetAuthorization() { authorized.removeAll(); denied = false }
    func readWithoutInteraction(_ slot: ModelSlot) async throws -> String? {
        guard authorized.contains(slot) else { throw SettingsError.credentialDenied }; return "test-only"
    }
    func read(_ slot: ModelSlot) async throws -> String? { try await readWithoutInteraction(slot) }
    func authorize(_ slot: ModelSlot) async throws -> String? {
        calls += 1
        lastAuthorizedSlot = slot
        try await Task.sleep(nanoseconds: 60_000_000)
        if denied { throw SettingsError.credentialDenied }
        authorized.insert(slot); return "test-only"
    }
    func write(_ secret: String, slot: ModelSlot) {}
    func remove(_ slot: ModelSlot) { authorized.remove(slot) }
}
private actor TenTransport: ConnectionTransport {
    var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        return (Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8), 200)
    }
}
@MainActor
enum StageTenAuthorizationSmokeRunner {
    static func run() async {
        setbuf(stdout, nil)
        var checks: [(String, Bool)] = []
        do {
            let root = DataDirectoryResolver.makeEphemeralDirectory(prefix: "jotbloom-10a")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let suite = "JotBloom.10a." + UUID().uuidString, base = TenCredentials(), transport = TenTransport()
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let credentials = CoordinatedCredentialStore(base: base)
            let model = SettingsViewModel(persistence: .init(defaults: defaults), credentials: credentials, login: IsolatedLoginItemService(), dataDirectory: root, tester: .init(transport: transport))
            model.mainURL = "https://fixture.invalid/v1"; model.mainModel = "fixture"
            var focusDepth = 0
            model.onSystemInteraction = { focusDepth += $0 ? 1 : -1 }
            for _ in 0..<3 { model.testConnection(.main); try await settle(model) }
            let earlyReads = await base.calls, earlyRequests = await transport.calls
            checks.append(("three_denied_tests_never_prompt_or_send", earlyReads == 0 && earlyRequests == 0 && model.credentialHelp.contains(.main)))
            model.recoverKeyAccess(.main); try await settle(model)
            let recoveredReads = await base.calls, recoveredRequests = await transport.calls
            checks.append(("explicit_recovery_only_authorizes_without_network", recoveredReads == 1 && recoveredRequests == 0 && focusDepth == 0))
            for _ in 0..<3 { model.testConnection(.main); try await settle(model) }
            let reads = await base.calls, requests = await transport.calls
            checks.append(("three_tests_reuse_explicit_recovery", reads == 1 && requests == 3))
            checks.append(("connection_success_and_focus_balanced", model.connectionStatus[.main]?.hasPrefix("连接成功") == true && focusDepth == 0))
            await base.revoke(); model.testConnection(.main); try await settle(model)
            let deniedReads = await base.calls, deniedRequests = await transport.calls
            checks.append(("revocation_stops_without_network_or_loop", deniedReads == 1 && deniedRequests == 3 && focusDepth == 0))
            await base.resetAuthorization()
            model.recoverKeyAccess(.main)
            try await Task.sleep(nanoseconds: 10_000_000)
            model.cancelTests()
            try await Task.sleep(nanoseconds: 100_000_000)
            let cancelledRequests = await transport.calls
            checks.append(("cancelled_recovery_never_sends_late_request", cancelledRequests == 3 && focusDepth == 0 && !model.readingCredential && model.feedback == "已取消恢复，原有密钥保持不变。"))
            await base.resetAuthorization()
            model.auxiliaryModel = "fixture-aux"; model.setAuxiliaryUsesMain(true)
            model.recoverKeyAccess(.auxiliary); try await settle(model)
            let sharedSlot = await base.lastAuthorizedSlot
            checks.append(("shared_aux_recovery_uses_main_slot", sharedSlot == .main))
            await base.resetAuthorization()
            model.auxiliaryURL = "https://fixture.invalid/v1"; model.setAuxiliaryUsesMain(false)
            model.recoverKeyAccess(.auxiliary); try await settle(model)
            let independentSlot = await base.lastAuthorizedSlot, afterRecoveryRequests = await transport.calls
            checks.append(("independent_aux_recovery_uses_aux_slot_without_network", independentSlot == .auxiliary && afterRecoveryRequests == 3 && focusDepth == 0))
            checks += try await keychainChecks(root)
            checks += try await interfaceChecks(root: root, settings: model, credentials: credentials, base: base)
            for (name, passed) in checks { print("JOTBLOOM_10A \(name)=\(passed)") }
            print("JOTBLOOM_10A passed=\(checks.filter(\.1).count)/\(checks.count) real_user_keychain=false real_network=false")
            fflush(stdout); exit(checks.allSatisfy(\.1) ? 0 : 1)
        } catch { print("JOTBLOOM_10A failed=\(error)"); fflush(stdout); exit(1) }
    }
    private static func settle(_ model: SettingsViewModel) async throws {
        for _ in 0..<300 { if model.testing.isEmpty && !model.readingCredential { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw SettingsError.timeout
    }
    private static func interfaceChecks(root: URL, settings: SettingsViewModel, credentials: any CredentialStoring, base: TenCredentials) async throws -> [(String, Bool)] {
        await base.revoke()
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let input = InspirationInputViewModel(store: store), library = InspirationLibraryViewModel(store: store)
        let assets = try ClipboardAssetStore(dataDirectoryURL: root)
        let service = ClipboardService(store: store, assetStore: assets)
        let named = NSPasteboard(name: .init("JotBloom.10a.quiet." + UUID().uuidString))
        defer { named.releaseGlobally() }
        let writer = SystemPasteboardClient(pasteboard: named)
        let clipboard = ClipboardHistoryViewModel(service: service, pasteboardWriter: writer)
        let search = GlobalSearchViewModel(store: store, pasteboardWriter: writer, debounceNanoseconds: 0)
        let prompts = PromptLibraryViewModel(store: store, writer: writer)
        let transport = TenChatTransport()
        let chat = ChatViewModel(store: store, credentials: credentials, configuration: { .init(baseURL: "https://fixture.invalid/v1", model: "fixture") }, transport: transport)
        let panel = PanelController(inspirationViewModel: input, clipboardViewModel: clipboard, inspirationLibraryViewModel: library, globalSearchViewModel: search, dataDirectory: root, settingsModel: settings, promptModel: prompts, chatModel: chat)
        defer { panel.close() }
        panel.debugSetAutomaticDismissalEnabled(false)
        input.start(); library.start(); clipboard.start(); await chat.start()
        _ = panel.present(); _ = panel.showChat()
        chat.draft = "测试权限失败后保留的草稿"; chat.send()
        for _ in 0..<200 { if !chat.busy { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 550_000_000)
        try panel.debugCapturePromptPanel(to: root.appendingPathComponent("chat-key-help.png"))
        let calls = await transport.calls
        var checks = [("chat_denied_preserves_draft_and_offers_settings", calls == 0 && chat.needsCredentialHelp && chat.draft == "测试权限失败后保留的草稿")]
        chat.onOpenSettings?()
        try await Task.sleep(nanoseconds: 550_000_000)
        checks.append(("credential_help_routes_to_settings", panel.debugSettingsOpen))
        try panel.debugCapturePromptPanel(to: root.appendingPathComponent("settings-key-help.png"))
        print("JOTBLOOM_10A screenshots=\(root.path)")
        return checks
    }
    private static func keychainChecks(_ root: URL) async throws -> [(String, Bool)] {
        // Only this disposable keychain is searched, edited, locked or deleted.
        let password = "fixture-" + UUID().uuidString
        var created: SecKeychain?
        let status = password.withCString { pointer in root.appendingPathComponent("fixture.keychain").path.withCString {
            SecKeychainCreate($0, UInt32(password.utf8.count), pointer, false, nil, &created)
        } }
        print("JOTBLOOM_10A fixture_create_status=\(status)")
        guard status == errSecSuccess, let keychain = created else { throw SettingsError.credentialUnavailable }
        defer { SecKeychainDelete(keychain) }
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw SettingsError.credentialUnavailable }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        let service = "fixture." + UUID().uuidString
        let base = KeychainCredentialStore(service: service, scopedKeychain: keychain)
        print("JOTBLOOM_10A fixture_step=write")
        try await base.write("isolated-key", slot: .main)
        print("JOTBLOOM_10A fixture_step=read")
        let first = try await base.read(.main)
        print("JOTBLOOM_10A fixture_step=silent_read")
        let second = try await base.readWithoutInteraction(.main)
        var checks = [("native_reuse_without_ui", first == "isolated-key" && second == first)]
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: ModelSlot.main.account, kSecMatchSearchList as String: [keychain]]
        // Changing a file-based keychain ACL can itself require system approval.
        // Do not manufacture that approval in unattended smoke tests.
        print("JOTBLOOM_10A native_acl_mutation=not_verified_requires_interactive_fixture")
        _ = try await base.read(.main)
        guard SecKeychainLock(keychain) == errSecSuccess else { throw SettingsError.credentialUnavailable }
        do { _ = try await base.readWithoutInteraction(.main); checks.append(("locked_keychain_invalidates_cache", false)) }
        catch { checks.append(("locked_keychain_invalidates_cache", true)) }
        let unlocked = password.withCString { SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true) }
        guard unlocked == errSecSuccess else { throw SettingsError.credentialUnavailable }
        _ = try await base.read(.main)
        guard SecItemDelete(query as CFDictionary) == errSecSuccess else { throw SettingsError.credentialUnavailable }
        do { let value = try await base.readWithoutInteraction(.main); checks.append(("external_delete_never_returns_old_key", value == nil)) }
        catch { checks.append(("external_delete_never_returns_old_key", true)) }
        return checks
    }
}
private actor TenChatTransport: ChatStreamingTransport {
    var calls = 0
    func stream(_ request: URLRequest, onText: @escaping @Sendable (String) async throws -> Void) async throws -> ChatStatus {
        calls += 1; throw SettingsError.network
    }
}
#endif
