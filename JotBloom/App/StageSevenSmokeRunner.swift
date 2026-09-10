#if DEBUG
import AppKit
import Carbon.HIToolbox
import Darwin
import JotBloomCore
import Security

private actor StageSevenTransport: ConnectionTransport {
    var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        return (Data(#"{"choices":[{"message":{"role":"assistant","content":"随手记录助手"}}]}"#.utf8), 200)
    }
}
@MainActor
enum StageSevenSmokeRunner {
    static func run() async {
        let root = DataDirectoryResolver.makeEphemeralDirectory(prefix: "jotbloom-stage7-smoke")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("jotbloom-stage7-ui-" + UUID().uuidString)
        let named = NSPasteboard(name: .init("JotBloom.Stage7." + UUID().uuidString))
        let generalBefore = NSPasteboard.general.changeCount
        let suite = "JotBloom.Stage7." + UUID().uuidString
        var checks: [(String, Bool)] = []
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let store = try JotBloomStore(dataDirectoryURL: root)
            defer { store.close() }
            let input = InspirationInputViewModel(store: store)
            let library = InspirationLibraryViewModel(store: store)
            let assets = try ClipboardAssetStore(dataDirectoryURL: root)
            let service = ClipboardService(store: store, assetStore: assets)
            let writer = SystemPasteboardClient(pasteboard: named)
            let clipboard = ClipboardHistoryViewModel(service: service, pasteboardWriter: writer)
            let search = GlobalSearchViewModel(store: store, pasteboardWriter: writer, debounceNanoseconds: 0)
            let prompts = PromptLibraryViewModel(store: store, writer: writer)
            let credentials = MemoryCredentialStore(), transport = StageSevenTransport()
            let settings = SettingsViewModel(persistence: AppSettingsStore(defaults: UserDefaults(suiteName: suite)!), credentials: credentials,
                login: IsolatedLoginItemService(), dataDirectory: root, tester: .init(transport: transport))
            let panel = PanelController(inspirationViewModel: input, clipboardViewModel: clipboard, inspirationLibraryViewModel: library,
                globalSearchViewModel: search, dataDirectory: root, settingsModel: settings, promptModel: prompts)
            defer { panel.close() }
            panel.debugSetAutomaticDismissalEnabled(false)
            input.savePrompt = { text, token, time in try await store.saveInputPrompt(content: text, token: token, timestamp: time) }
            input.start(); library.start(); clipboard.start()
            try await wait { input.isReady && library.isReady && clipboard.isReady }
        checks.append(("schema_v7_regression", try store.schemaVersionSynchronously() == 7))
            checks.append(("prompts_available_default", PanelSlot.prompts.isAvailable && PanelPreferences(defaultSlot: .prompts).defaultSlot == .prompts))
            checks.append(("chat_released_stage8", PanelSlot.chat.isAvailable))
            let original = "把灵感变成可复用的提示词\n为下面的内容提炼要点，保留事实与原文中的不确定性。"
            input.text = original; input.saveToPrompt()
            await input.waitForPendingSave()
            prompts.activate(); try await wait { !prompts.isLoading }
            guard let first = prompts.items.first else { throw PromptError.missing }
            checks.append(("input_saved_full_text_and_consumed_draft", try first.content == original && input.text.isEmpty && store.loadDraftSynchronously(kind: .inspiration) == nil))
            checks.append(("input_prompt_not_in_recent_inspirations", try store.listRecentInspirationsSynchronously().isEmpty))
            _ = try store.upsertClipboardTextSynchronously(text: "复用的提示词\n记录今天最重要的一个想法。", contentType: .text, copiedAtUTCms: 2,
                sourceApplication: .init(name: "隔离示例", bundleIdentifier: "test.stage7"))
            let source = try store.listClipboardItemsSynchronously()[0]
            let beforeSave = named.changeCount
            prompts.saveClipboard(source.id, to: .prompt); try await wait { !prompts.busy }
            prompts.saveClipboard(source.id, to: .inspiration); try await wait { !prompts.busy }
            checks.append(("cross_saves_do_not_copy", named.changeCount == beforeSave))
            let rows = try await store.listPrompts()
            checks.append(("both_targets_persisted", try rows.count == 2 && store.listRecentInspirationsSynchronously().count == 1))
            prompts.saveClipboard(source.id, to: .prompt); try await wait { !prompts.busy }
            let repeated = try await store.listPrompts()
            checks.append(("duplicate_save_idempotent", repeated.count == 2))
            let result = try store.searchAllSynchronously(query: "提示词")
            checks.append(("all_three_search_sources", !result.clipboard.isEmpty && !result.prompts.isEmpty && !result.inspirations.isEmpty))
            _ = panel.present(); panel.debugSelectPrompts()
            try await wait { panel.debugSnapshot.selectedTab == "prompts" && !prompts.isLoading }
            try await Task.sleep(nanoseconds: 450_000_000)
            checks.append(("native_prompt_route_compact", panel.debugSnapshot.isVisible && !panel.debugSnapshot.isExpanded))
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("prompts-300.png"))
            _ = panel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_DownArrow), modifiers: .command)
            try await Task.sleep(nanoseconds: 450_000_000)
            checks.append(("native_prompt_route_expanded", panel.debugSnapshot.isExpanded))
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("prompts-700.png"))
            prompts.beginEditing(first); prompts.editedTitle = "手动命名标题"
            panel.openSettings()
            checks.append(("rename_flushed_before_settings", try store.promptSynchronously(id: first.id)?.title == "手动命名标题"))
            panel.debugSelectPrompts()
            prompts.beginEditing(first); prompts.editedTitle = " "
            checks.append(("invalid_title_blocks_dismissal", !panel.prepareForDismissal() && prompts.editingID != nil))
            prompts.cancelEdit()
            let beforeCopy = named.changeCount
            prompts.copy(first.id, collapse: false); try await wait { !prompts.busy }
            checks.append(("copy_full_text_keeps_panel", named.changeCount > beforeCopy && named.string(forType: .string) == original && panel.debugSnapshot.isVisible))
            search.query = "手动命名"; try await wait { search.phase == .results }
            checks.append(("renamed_prompt_searchable", search.snapshot.prompts.first?.id.recordID == first.id))
            checks.append(("search_prompt_command_c_handled", search.copySelectedWithoutCollapsing()))
            try await Task.sleep(nanoseconds: 30_000_000)
            checks.append(("search_prompt_copies_original", named.string(forType: .string) == original))
            prompts.delete(first.id); try await wait { !prompts.busy }
            checks.append(("delete_has_undo", try prompts.canUndo && store.promptSynchronously(id: first.id) == nil))
            prompts.undoDeletion(); try await wait { !prompts.busy }
            checks.append(("undo_restores_content", try store.promptSynchronously(id: first.id)?.content == original))
            _ = try store.deleteClipboardItemSynchronously(id: source.id)
            let retainedPrompts = try await store.listPrompts()
            checks.append(("source_cleanup_keeps_targets", try retainedPrompts.count == 2 && store.listRecentInspirationsSynchronously().count == 1))
            await credentials.write("stage7-fixture-key", slot: .main)
            var config = AppSettings(); config.main = ModelConfiguration(baseURL: "https://fixture.invalid/v1", model: "fixture")
            let titles = PromptTitleCoordinator(store: store, credentials: credentials, settings: { config }, service: .init(transport: transport))
            let aiRow = try await store.saveInputPrompt(content: "用于生成标题的无敏感测试内容", token: "ai", timestamp: 3)
            titles.enqueue(aiRow.id); try await wait { titles.activeCount == 0 }
            checks.append(("fake_title_backfill", try store.promptSynchronously(id: aiRow.id)?.titleSource == .ai))
            let calls = await transport.calls
            checks.append(("one_title_request", calls == 1))
            // Only query a guaranteed random missing service, never the user's API accounts.
            var before: DarwinBoolean = false, after: DarwinBoolean = false
            let beforeStatus = SecKeychainGetUserInteractionAllowed(&before)
            let isolated = KeychainCredentialStore(service: "test.jotbloom.missing." + UUID().uuidString)
            let absent = try? await isolated.readWithoutInteraction(.main)
            let afterStatus = SecKeychainGetUserInteractionAllowed(&after)
            checks.append(("noninteractive_missing_service_restores_process_flag", beforeStatus == errSecSuccess && afterStatus == errSecSuccess && before.boolValue == after.boolValue && absent == nil))
            // The user changed the prompt primary action from copy to explicit editing.
            panel.debugSelectPrompts()
            let beforeEdit = named.changeCount
            prompts.select(first.id); prompts.openSelected()
            try await wait { !prompts.busy && prompts.detailID == first.id }
            try await Task.sleep(nanoseconds: 450_000_000)
            checks.append(("prompt_enter_opens_editor_without_copy", named.changeCount == beforeEdit && panel.debugSnapshot.isVisible && panel.debugSnapshot.isExpanded))
            prompts.detailTitle = "编辑后标题"; prompts.detailContent = "编辑后的完整正文\n最后一行"
            panel.openSettings()
            checks.append(("unsaved_editor_blocks_navigation", prompts.hasUnsavedDetail && !panel.debugSettingsOpen && !panel.prepareForDismissal()))
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("prompt-editor-700.png"))
            prompts.saveDetail(); try await wait { !prompts.busy }
            checks.append(("editor_overwrites_same_record", try store.promptSynchronously(id: first.id)?.content == "编辑后的完整正文\n最后一行" && !prompts.hasUnsavedDetail))
            prompts.detailTitle = "独立副本"; prompts.detailContent = "另存为新的完整正文"
            prompts.saveDetail(asNew: true); try await wait { !prompts.busy }
            let newID = prompts.detailID
            checks.append(("editor_save_as_independent", try newID != first.id && store.promptSynchronously(id: first.id)?.title == "编辑后标题" && store.promptSynchronously(id: newID!)?.title == "独立副本"))
            prompts.copyDetail()
            checks.append(("editor_copy_stays_open", named.string(forType: .string) == "另存为新的完整正文" && panel.debugSnapshot.isVisible))
            prompts.detailContent = "未保存内容"
            _ = prompts.closeEditor(discard: true)
            checks.append(("editor_discard_preserves_stored_body", try prompts.detailID == nil && store.promptSynchronously(id: newID!)?.content == "另存为新的完整正文"))
            search.query = "独立副本"; try await wait { search.phase == .results }
            search.activateSelected(); try await wait { !prompts.busy && prompts.detailID == newID }
            checks.append(("search_prompt_opens_editor", prompts.detailID == newID))
            _ = prompts.closeEditor()
            let duplicateText = "查重验收\n同一段完整正文"
            let duplicateParsed = InspirationTextParser.parse(duplicateText)!
            let duplicateFirst = try store.saveManualInspirationSynchronously(duplicateParsed, timestampUTCms: 100)
            input.text = duplicateText; input.save(); await input.waitForPendingSave()
            checks.append(("duplicate_inspiration_preserves_input", input.text == duplicateText && input.feedback?.message.contains("已存在") == true))
            _ = try store.upsertClipboardTextSynchronously(text: duplicateText, contentType: .text, copiedAtUTCms: 100, sourceApplication: .init(name: "隔离查重", bundleIdentifier: nil))
            let duplicateSource = try store.listClipboardItemsSynchronously().first { $0.textContent == duplicateText }!
            let deduplicated = try await store.saveClipboard(id: duplicateSource.id, to: .inspiration, timestamp: 101)
            checks.append(("cross_entry_inspiration_deduplicated", !deduplicated.created && deduplicated.id == duplicateFirst.id))
            _ = try store.upsertClipboardTextSynchronously(text: "保存此刻的灵感\n完整原文会独立保存到目标库。", contentType: .text, copiedAtUTCms: Int64(Date().timeIntervalSince1970 * 1000), sourceApplication: .init(name: "隔离示例", bundleIdentifier: "test.stage7"))
            panel.debugSelectClipboard(); clipboard.refreshAfterMaintenance()
            try await Task.sleep(nanoseconds: 60_000_000)
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("clipboard-actions.png"))
            panel.debugSelectInspiration()
            try await Task.sleep(nanoseconds: 60_000_000)
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("input-actions.png"))
            if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE7_PERFORMANCE"] == "1" {
                checks.append(("three_source_search_20_rounds", try await performance(store)))
            }
            checks.append(("general_pasteboard_untouched", NSPasteboard.general.changeCount == generalBefore))
            print("JOTBLOOM_STAGE7_UI \(output.path)")
        } catch { checks.append(("unexpected_error", false)); print("JOTBLOOM_STAGE7_ERROR \(type(of: error))") }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        named.releaseGlobally()
        for (name, pass) in checks { print("JOTBLOOM_STAGE7_CHECK \(name)=\(pass)") }
        let passed = !checks.isEmpty && checks.allSatisfy(\.1)
        print("JOTBLOOM_STAGE7_SMOKE success=\(passed) checks=\(checks.count) real_api_tested=false real_user_keychain_tested=false")
        fflush(stdout); exit(passed ? 0 : 1)
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw SettingsError.timeout
    }
    private static func performance(_ store: JotBloomStore) async throws -> Bool {
        let body = String(repeating: "无敏感数据的本地检索样本。", count: 24)
        var textBytes = 0
        for index in 0..<200 {
            let text = "Stage7-common \(index) \(body) tail-\(index)"
            textBytes += text.utf8.count * 3
            _ = try store.upsertClipboardTextSynchronously(text: text, contentType: .text,
                copiedAtUTCms: Int64(index), sourceApplication: .init(name: "性能样本", bundleIdentifier: nil))
            guard let id = try store.listClipboardItemsSynchronously().first(where: { $0.textContent?.hasPrefix("Stage7-common \(index) ") == true })?.id else { throw PromptError.sourceMissing }
            _ = try await store.saveClipboard(id: id, to: .prompt, timestamp: Int64(index))
            _ = try await store.saveClipboard(id: id, to: .inspiration, timestamp: Int64(index))
        }
        let all = try await store.searchAll(query: "Stage7-common")
        guard all.clipboard.count == 200, all.prompts.count == 200, all.inspirations.count == 200 else { return false }
        var passed = true
        let queries = ["Stage7-common", "tail-199", "无敏感", "stage7-no-result"]
        for round in 1...20 {
            var durations: [Double] = []
            for index in 0..<100 {
                let started = ProcessInfo.processInfo.systemUptime
                _ = try await store.searchAll(query: queries[index % queries.count])
                durations.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
            durations.sort()
            var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
            }
            guard status == KERN_SUCCESS else { throw SettingsError.responseInvalid }
            let memory = Double(info.resident_size) / 1_048_576
            let pass = durations[94] < 100 && memory < 150
            passed = passed && pass
            print(String(format: "JOTBLOOM_STAGE7_PERF round=%d queries=100 fixture_records=600 fixture_utf8_bytes=%d debounce_excluded=true p50_ms=%.3f p95_ms=%.3f max_ms=%.3f resident_mb=%.3f passed=%@", round, textBytes, durations[49], durations[94], durations[99], memory, String(pass)))
            fflush(stdout)
        }
        return passed
    }
}
#endif
