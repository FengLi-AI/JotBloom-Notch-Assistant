#if DEBUG
import AppKit
import Carbon.HIToolbox
import Darwin
import JotBloomCore

@MainActor
enum StageTenOperationsSmokeRunner {
    static func run() async {
        setbuf(stdout, nil)
        let root = DataDirectoryResolver.makeEphemeralDirectory(prefix: "jotbloom-10b")
        let suite = "JotBloom.10b." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let named = NSPasteboard(name: .init(suite))
        let before = NSPasteboard.general.changeCount
        var checks: [(String, Bool)] = []
        do {
            let store = try JotBloomStore(dataDirectoryURL: root)
            let service = ClipboardService(store: store, assetStore: try ClipboardAssetStore(dataDirectoryURL: root))
            let writer = SystemPasteboardClient(pasteboard: named)
            let input = InspirationInputViewModel(store: store)
            let library = InspirationLibraryViewModel(store: store)
            let clipboard = ClipboardHistoryViewModel(service: service, pasteboardWriter: writer)
            let search = GlobalSearchViewModel(store: store, pasteboardWriter: writer, debounceNanoseconds: 0)
            let prompts = PromptLibraryViewModel(store: store, writer: writer)
            let settings = SettingsViewModel(persistence: .init(defaults: defaults), credentials: MemoryCredentialStore(), login: IsolatedLoginItemService(), dataDirectory: root)
            settings.onClearSnapshot = { try await store.listClipboardItems() }
            settings.onClear = { snapshot in try await service.clearHistory(snapshot: snapshot) }
            clipboard.onClearHistory = settings.onClear
            let panel = PanelController(inspirationViewModel: input, clipboardViewModel: clipboard, inspirationLibraryViewModel: library, globalSearchViewModel: search, dataDirectory: root, settingsModel: settings, promptModel: prompts)
            panel.debugSetAutomaticDismissalEnabled(false)
            input.start(); library.start(); clipboard.start()
            try await wait { input.isReady && library.isReady && clipboard.isReady }
            _ = panel.present()

            input.text = "每周复盘\n把下周要做的事情整理成三个行动。"; input.save()
            try await wait { input.text.isEmpty }
            let inspiration = try store.listRecentInspirationsSynchronously().first!
            panel.debugSelectInspirationLibrary()
            try await wait { library.items.contains { $0.id == inspiration.id } }
            panel.debugOpenTenBInspiration(inspiration.id)
            try await wait { library.screen == .detail && !library.isDetailLoading }
            library.detailBody += "\n先从最小的一步开始。"
            checks.append(("autosave_pending_visible", library.saveStatusMessage == "自动保存中…"))
            try await wait { !library.hasPendingSave }
            checks.append(("autosave_saved_visible", library.saveStatusMessage == "已保存"))
            try await capture(panel, "inspiration-saved-700", root)
            _ = panel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_Escape))
            try await wait { library.screen == .list }
            checks.append(("inspiration_return_selection", library.selectedID == inspiration.id))

            let original = try await store.saveInputPrompt(content: "每周复盘：整理本周成果和下周行动。", token: UUID().uuidString, timestamp: 1).id
            try await store.setPromptFavorite(id: original, favorite: true)
            panel.debugSelectPrompts(); prompts.favoritesOnly = true
            try await wait { !prompts.isLoading }
            prompts.openEditor(original); try await wait { !prompts.busy }
            prompts.detailContent = "每周复盘：分成成果、问题、下周行动三个部分。"
            checks.append(("unsaved_return_blocked", !prompts.returnFromDetail() && prompts.detailID == original))
            prompts.saveDetail(asNew: true); try await wait { !prompts.busy && !prompts.isLoading }
            let copy = prompts.savedCopyID!
            let originalContent = try store.promptSynchronously(id: original)?.content
            checks.append(("save_as_keeps_filter_and_original", prompts.favoritesOnly && copy != original && originalContent == "每周复盘：整理本周成果和下周行动。"))
            try await capture(panel, "prompt-copy-action-700", root)
            prompts.viewSavedCopy(); try await wait { !prompts.isLoading }
            checks.append(("reveal_switches_all_and_selects_copy", !prompts.favoritesOnly && prompts.detailID == nil && prompts.selectedID == copy))
            prompts.copy(copy, collapse: false); try await wait { !prompts.busy }
            checks.append(("copy_keeps_panel_and_full_text", named.string(forType: .string) == "每周复盘：分成成果、问题、下周行动三个部分。" && panel.debugSnapshot.isVisible))
            panel.debugSetExpanded(false)
            try await capture(panel, "prompt-copy-located-300", root)

            panel.debugSetExpanded(false)
            panel.debugSelectGlobalSearch(); search.query = "每周复盘"
            checks.append(("search_entry_auto_expands", panel.debugSnapshot.isExpanded))
            panel.debugSetExpanded(false)
            checks.append(("search_manual_compact_available", !panel.debugSnapshot.isExpanded))
            panel.debugSelectGlobalSearch()
            checks.append(("search_reselect_expands", panel.debugSnapshot.isExpanded))
            panel.debugSetExpanded(false)
            let searchShortcutHandled = panel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_F), modifiers: .command)
            checks.append(("search_shortcut_auto_expands", searchShortcutHandled && panel.debugSnapshot.isExpanded))
            let defaultSearchState = PanelViewState()
            defaultSearchState.preferences.defaultSlot = .globalSearch
            defaultSearchState.resetForPresentation()
            checks.append(("search_default_page_auto_expands", defaultSearchState.selectedTab == .globalSearch && defaultSearchState.isExpanded))
            try await wait { search.phase == .results }
            search.activate(.init(source: .prompt, recordID: original)); try await wait { !prompts.busy && prompts.detailID != nil }
            checks.append(("search_editor_names_origin", prompts.editorBackName == "搜索结果"))
            _ = prompts.returnFromDetail(); try await wait { search.phase == .results }
            checks.append(("search_return_preserves_query", panel.debugSnapshot.selectedTab == "globalSearch" && search.query == "每周复盘"))
            search.query = "不存在的隔离关键词"; try await wait { search.phase == .empty }
            panel.debugSetExpanded(false)
            try await capture(panel, "search-empty-300", root)

            let source = ClipboardSourceApplication(name: "隔离测试", bundleIdentifier: "fixture")
            _ = try await service.capture(.init(content: .text("清理前的文本"), copiedAtUTCms: 1, sourceApplication: source))
            panel.debugSelectClipboard(); clipboard.refreshAfterMaintenance(); panel.debugSetExpanded(true)
            try await wait { clipboard.items.count == 1 }
            clipboard.confirmingClear = true
            try await capture(panel, "clipboard-clear-confirmation-700", root)
            checks.append(("clear_blocks_panel_dismissal", !panel.prepareForDismissal() && clipboard.clearConfirmationMessage.contains("1 条")))
            clipboard.confirmingClear = false
            checks.append(("cancel_clear_retains_record", try store.listClipboardItemsSynchronously().count == 1))
            clipboard.confirmingClear = true
            _ = try await service.capture(.init(content: .text("确认期间新增的文本"), copiedAtUTCms: 2, sourceApplication: source))
            clipboard.clearConfirmed(); try await wait { !clipboard.isClearing }
            checks.append(("clear_keeps_later_record", try store.listClipboardItemsSynchronously().map(\.textContent) == ["确认期间新增的文本"]))

            panel.debugStageNineSettings(section: "clipboard"); try await settle()
            settings.prepareClearHistory(); try await wait { !settings.busy }
            checks.append(("settings_clear_snapshot_count", settings.clearSnapshot.count == 1 && settings.blocksPanelInteraction))
            settings.confirmingClear = false
            checks.append(("settings_cancel_no_write", try store.listClipboardItemsSynchronously().count == 1))
            panel.debugStageNineSettings(section: "systemPrompt"); try await settle()
            settings.systemPromptDraft = "先帮我明确目标。"
            checks.append(("system_prompt_unsaved_guard", !settings.allowLeavingPrompt()))
            settings.discardSystemPrompt()
            checks.append(("system_prompt_discard_returns_saved", settings.allowLeavingPrompt() && !settings.hasUnsavedSystemPrompt))
            for index in 1...4 {
                _ = try await service.capture(.init(content: .text("每周复盘：剪贴板分类测试 \(index)"), copiedAtUTCms: Int64(index + 10), sourceApplication: source))
                _ = try await store.saveInputPrompt(content: "每周复盘：提示词分类测试 \(index)", token: UUID().uuidString, timestamp: Int64(index + 10))
            }
            panel.debugSelectGlobalSearch(); search.selectScope(.all); search.query = "每周复盘"
            try await wait { search.phase == .results && search.count(for: .all) == 11 }
            checks.append(("search_all_limits_preview_not_counts", search.visibleResults.count == 5 && search.count(for: .prompt) == 6 && search.count(for: .clipboard) == 4))
            panel.debugSetExpanded(false)
            try await capture(panel, "search-scopes-all-300", root)
            panel.debugSetExpanded(true)
            try await capture(panel, "search-scopes-all-700", root)
            search.moveSelection(by: 2)
            checks.append(("search_keyboard_skips_hidden_rows", search.selectedID?.source == .prompt))
            search.selectScope(.prompt)
            search.select(.init(source: .prompt, recordID: original))
            search.activateSelected(); try await wait { !prompts.busy && prompts.detailID == original }
            _ = prompts.returnFromDetail(); try await wait { search.phase == .results }
            checks.append(("search_scope_survives_native_editor_return", search.scope == .prompt && search.query == "每周复盘" && search.selectedID == .init(source: .prompt, recordID: original)))
            panel.debugSetExpanded(false)
            try await capture(panel, "search-scopes-prompt-300", root)
            search.query = "剪贴板分类测试"; try await wait { search.phase == .results }
            checks.append(("search_zero_scope_keeps_other_counts", search.count(for: .prompt) == 0 && search.count(for: .clipboard) == 4 && search.visibleResults.isEmpty && search.selectedID == nil))
            try await capture(panel, "search-scopes-zero-300", root)
            search.selectScope(.all)
            checks.append(("search_zero_scope_recovers_all", search.query == "剪贴板分类测试" && search.visibleResults.count == 2))
            checks += try await panel.debugRunPlaceholderProbe(output: root)
            if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE10C_SMOKE"] == "1" {
                _ = try await service.capture(.init(content: .text("来自 Finder 的文件说明：先记录，再整理。"), copiedAtUTCms: 1_788_860_000_000,
                    sourceApplication: .init(name: "Finder", bundleIdentifier: "com.apple.finder")))
                clipboard.refreshAfterMaintenance()
                checks += try await panel.debugRunTenCVisualProbe(output: root)
            }
            checks.append(("general_pasteboard_untouched", NSPasteboard.general.changeCount == before))
            try await input.prepareForTermination(); _ = await library.prepareForTermination()
            await clipboard.prepareForTermination(); _ = await prompts.prepareForMaintenance()
            panel.close(); store.close(); named.releaseGlobally(); defaults.removePersistentDomain(forName: suite)
            for (name, passed) in checks { print("JOTBLOOM_10B \(name)=\(passed)") }
            print("JOTBLOOM_10B output=\(root.path) passed=\(checks.filter(\.1).count)/\(checks.count) real_network=false")
            fflush(stdout); exit(checks.allSatisfy(\.1) ? 0 : 1)
        } catch {
            print("JOTBLOOM_10B fixture_error=\(error)"); fflush(stdout); exit(1)
        }
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 550_000_000) }
    private static func capture(_ panel: PanelController, _ name: String, _ root: URL) async throws {
        try await settle(); try panel.debugCapturePromptPanel(to: root.appendingPathComponent(name + ".png"))
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        print("JOTBLOOM_10B timeout_line=\(line)")
        throw ChatError.busy
    }
}
#endif
