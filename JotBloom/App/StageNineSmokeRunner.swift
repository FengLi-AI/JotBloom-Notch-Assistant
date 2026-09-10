#if DEBUG
import AppKit
import Carbon.HIToolbox
import Darwin
import JotBloomCore

private actor NineSmokeTransport: ChatStreamingTransport {
    func stream(_ request: URLRequest, onText: @escaping @Sendable (String) async throws -> Void) async throws -> ChatStatus {
        try await onText(#"{"title":"个人作品导航工具","body":"为求职者做一个轻量的作品导航页面。核心不是复杂的网站生成，而是清楚地展示代表作品和个人经历。\n\n先制作一个可使用的小样，请几位目标用户试用，再判断是否需要模板和自定义排版。\n\n待验证：用户是否愿意持续更新，以及现有工具在哪一步不够顺手。"}"#)
        return .complete
    }
}
@MainActor
enum StageNineSmokeRunner {
    static func run() async {
        let root = DataDirectoryResolver.makeEphemeralDirectory(prefix: "jotbloom-stage9-smoke")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("jotbloom-stage9-ui-" + UUID().uuidString)
        let suite = "JotBloom.Stage9." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let named = NSPasteboard(name: .init("JotBloom.Stage9." + UUID().uuidString))
        let before = NSPasteboard.general.changeCount
        var checks: [(String, Bool)] = []
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
            let input = InspirationInputViewModel(store: store), library = InspirationLibraryViewModel(store: store)
            let assets = try ClipboardAssetStore(dataDirectoryURL: root)
            let service = ClipboardService(store: store, assetStore: assets), writer = SystemPasteboardClient(pasteboard: named)
            let clipboard = ClipboardHistoryViewModel(service: service, pasteboardWriter: writer)
            let search = GlobalSearchViewModel(store: store, pasteboardWriter: writer, debounceNanoseconds: 0)
            let prompts = PromptLibraryViewModel(store: store, writer: writer)
            let credentials = MemoryCredentialStore(); await credentials.write("fixture", slot: .main)
            let settings = SettingsViewModel(persistence: AppSettingsStore(defaults: defaults), credentials: credentials, login: IsolatedLoginItemService(), dataDirectory: root)
            let chat = ChatViewModel(store: store, credentials: credentials, configuration: { .init(baseURL: "https://example.test/v1", model: "fixture") }, transport: NineSmokeTransport(), defaultSystemPrompt: { settings.value.chatSystemPrompt })
            var turn = try await store.submitChat("如何把作品集做成简单的网站？", token: "fixture", source: .aiChat)
            turn.answer = "先围绕作品导航做一个小样，验证用户是否需要持续更新。"; turn.status = .complete; try await store.updateChat(turn)
            let panel = PanelController(inspirationViewModel: input, clipboardViewModel: clipboard, inspirationLibraryViewModel: library, globalSearchViewModel: search, dataDirectory: root, settingsModel: settings, promptModel: prompts, chatModel: chat)
            defer { panel.close() }
            panel.debugSetAutomaticDismissalEnabled(false)
            input.start(); library.start(); clipboard.start(); await chat.start()
            try await wait { input.isReady && library.isReady && clipboard.isReady }
            _ = panel.present(); _ = panel.showChat()
            if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE10C_SMOKE"] == "1" {
                panel.debugSetExpanded(true); try await settle()
                try panel.debugCapturePromptPanel(to: output.appendingPathComponent("10c-chat-700.png"))
                chat.toggleHistory(); try await wait { chat.showingHistory }; try await settle()
                try panel.debugCapturePromptPanel(to: output.appendingPathComponent("10c-chat-history-700.png"))
                chat.toggleHistory(); try await settle()
            }
            checks.append(("summary_shortcut", panel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_S), modifiers: .command)))
            try await wait { !chat.busy }; try await settle()
            let beforeSave = try store.listRecentInspirationsSynchronously()
            checks.append(("preview_expanded_and_not_saved", chat.summaryPreview && panel.debugSnapshot.isExpanded && beforeSave.isEmpty))
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("summary-preview-700.png"))
            panel.debugSelectClipboard()
            checks.append(("preview_blocks_tab_loss", panel.debugSnapshot.selectedTab == "chat" && chat.summaryPreview))
            _ = panel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_S), modifiers: .command)
            try await wait { !chat.busy }
            let afterSave = try store.listRecentInspirationsSynchronously()
            checks.append(("save_summary_keeps_chat", !chat.summaryPreview && chat.turns.count == 1 && afterSave.count == 1))
            let historyID = chat.currentSession
            for _ in 0..<4 { chat.requestNew(); try await wait { !chat.busy } }
            checks.append(("repeated_blank_no_history", chat.sessions.count == 1 && chat.sessions[0].id == historyID))
            panel.debugStageNineSettings(section: "systemPrompt"); try await settle()
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("system-prompt-700.png"))
            settings.systemPromptDraft = "先帮我明确目标，再给建议。"
            _ = panel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_Comma), modifiers: .command)
            checks.append(("unsaved_prompt_blocks_back", panel.debugSettingsOpen && !settings.allowLeavingPrompt()))
            settings.saveSystemPrompt()
            checks.append(("prompt_saved", settings.value.chatSystemPrompt == "先帮我明确目标，再给建议。" && !settings.hasUnsavedSystemPrompt))
            settings.restoreDefaultSystemPrompt(); checks.append(("restore_requires_save", settings.hasUnsavedSystemPrompt))
            settings.discardSystemPrompt(); checks.append(("discard_keeps_saved", settings.systemPromptDraft == "先帮我明确目标，再给建议。"))
            panel.debugStageNineSettings(section: "ai"); try await settle()
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("inspiration-ai-opt-in.png"))
            checks.append(("enrichment_default_off", !settings.value.inspirationAIEnabled))
            checks.append(("general_pasteboard_untouched", NSPasteboard.general.changeCount == before))
            for (name, passed) in checks { print("JOTBLOOM_STAGE9 \(name)=\(passed)") }
            print("JOTBLOOM_STAGE9 output=\(output.path) passed=\(checks.filter(\.1).count)/\(checks.count)")
            defaults.removePersistentDomain(forName: suite)
            fflush(stdout); exit(checks.allSatisfy(\.1) ? 0 : 1)
        } catch { print("JOTBLOOM_STAGE9 fixture_error=\(error)"); fflush(stdout); exit(1) }
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 500_000_000) }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw ChatError.busy
    }
}
#endif
