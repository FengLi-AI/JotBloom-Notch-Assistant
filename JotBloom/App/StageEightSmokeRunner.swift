#if DEBUG
import AppKit
import Carbon.HIToolbox
import Darwin
import JotBloomCore

private actor StageEightTransport: ChatStreamingTransport {
    func stream(_ request: URLRequest, onText: @escaping @Sendable (String) async throws -> Void) async throws -> ChatStatus {
        for text in ["可以从三个方向想：", "把随手记下的念头做成可检索的素材库；", "每天选一个想法做小实验；", "从工作记录中提炼可复用的方法。\n", "你现在更需要积累素材，还是把一个已有想法做出来？"] {
            try await onText(text); try await Task.sleep(nanoseconds: 140_000_000)
        }
        return .complete
    }
}
@MainActor
enum StageEightSmokeRunner {
    static func run() async {
        let root = DataDirectoryResolver.makeEphemeralDirectory(prefix: "jotbloom-stage8-smoke")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("jotbloom-stage8-ui-" + UUID().uuidString)
        let named = NSPasteboard(name: .init("JotBloom.Stage8." + UUID().uuidString))
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
            let credentials = MemoryCredentialStore(); await credentials.write("isolated-fixture", slot: .main)
            let chat = ChatViewModel(store: store, credentials: credentials, configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: StageEightTransport())
            let panel = PanelController(inspirationViewModel: input, clipboardViewModel: clipboard, inspirationLibraryViewModel: library,
                globalSearchViewModel: search, dataDirectory: root, promptModel: prompts, chatModel: chat)
            defer { panel.close() }
            panel.debugSetAutomaticDismissalEnabled(false)
            input.sendToChat = { text in guard panel.showChat() else { throw ChatError.busy }; try await chat.sendFromInspiration(text) }
            if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE8_PERFORMANCE"] == "1" {
                for index in 0..<100 {
                    var turn = try await store.submitChat("单面板性能样本 \(index)", token: UUID().uuidString, source: .aiChat)
                    turn.answer = String(repeating: "用于性能验证的无敏感文字。", count: 10); turn.status = .complete; try await store.updateChat(turn)
                }
                await chat.start(); _ = panel.present(); _ = panel.showChat()
                _ = panel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_DownArrow), modifiers: .command); try await settle()
                var memory = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let status = withUnsafeMutablePointer(to: &memory) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                } }
                let mb = Double(memory.phys_footprint) / 1048576
                print(String(format: "JOTBLOOM_STAGE8_SINGLE_PANEL turns=100 loaded=50 physical_footprint_mb=%.3f resident_peak_mb=%.3f under_150mb=%@", mb, Double(memory.resident_size_peak)/1048576, String(mb < 150 && status == KERN_SUCCESS)))
                fflush(stdout); exit(status == KERN_SUCCESS && mb < 150 ? 0 : 1)
            }
            input.start(); library.start(); clipboard.start(); await chat.start()
            try await wait { input.isReady && library.isReady && clipboard.isReady }
            _ = panel.present(); _ = panel.showChat(); try await settle()
            checks.append(("chat_native_compact", panel.debugSnapshot.selectedTab == "chat" && !panel.debugSnapshot.isExpanded))
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("chat-300.png"))
            checks += panel.debugChatInputProbe()
            chat.draft = "我想做一个轻量的个人灵感工具，如何验证方向？"; chat.send()
            try await wait { !chat.turns.isEmpty && !chat.turns[0].answer.isEmpty }
            checks.append(("first_delta_visible_while_busy", chat.busy))
            try await wait { !chat.busy }; try await settle()
            checks.append(("accepted_expands_700", panel.debugSnapshot.isExpanded && chat.turns[0].status == .complete))
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("chat-700.png"))
            chat.draft = "下一条未发送的草稿"
            panel.debugSelectClipboard(); _ = panel.showChat()
            checks.append(("tab_switch_keeps_chat_draft", chat.draft == "下一条未发送的草稿" && chat.turns.count == 1))
            panel.debugSelectInspiration(); input.text = "如何把产品想法变成一个小实验？"
            let shortcut = panel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_Return), modifiers: [.command, .shift])
            await input.waitForPendingSave(); try await wait { !chat.busy }
            checks.append(("discuss_shortcut_atomic_source", shortcut && input.text.isEmpty && chat.turns.count == 2 && chat.draft == "下一条未发送的草稿"))
            guard let originalSession = chat.sessions.first(where: \.isCurrent) else { throw ChatError.storage }
            _ = panel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_N), modifiers: .command)
            try await wait { !chat.busy }
            checks.append(("new_chat_preserves_history", chat.turns.isEmpty && chat.sessions.count == 1))
            chat.showingHistory = true; try await settle()
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("chat-history.png"))
            panel.debugSetExpanded(false); try await settle()
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("chat-history-300.png"))
            checks.append(("history_compact_route", !panel.debugSnapshot.isExpanded && chat.showingHistory))
            panel.debugSetExpanded(true); try await settle()
            chat.selectSession(originalSession); try await wait { !chat.busy }
            checks.append(("select_history_restores_draft", chat.turns.count == 2 && chat.draft == "下一条未发送的草稿"))
            chat.requestDelete(originalSession)
            checks.append(("delete_requires_confirmation", chat.confirmingDelete))
            chat.confirmingDelete = false
            chat.draft = "停止测试"; chat.send(); try await wait { chat.turns.count == 3 && chat.turns.last?.answer.isEmpty == false && chat.busy }
            chat.stop(); try await wait { !chat.busy }
            checks.append(("stop_partial_saved", try await store.chatPage().turns.last?.status == .stopped))
            chat.draft = "重启后仍保留"; let prepared = await chat.prepareForMaintenance()
            let restored = ChatViewModel(store: store, credentials: credentials, configuration: { ModelConfiguration() }, transport: StageEightTransport())
            await restored.start()
            checks.append(("restart_restores_without_auto_send", prepared && restored.turns.count == 3 && restored.draft == "重启后仍保留" && !restored.busy))
            panel.debugSelectInspirationLibrary(); library.filter(.article); try await wait { library.isReady }; try await settle()
            try panel.debugCapturePromptPanel(to: output.appendingPathComponent("category-empty.png"))
            checks.append(("category_route_empty_state", library.items.isEmpty && library.filterCategory == .article))
            for index in 0..<80 {
                var turn = try await store.submitChat("长会话样本 \(index)", token: UUID().uuidString, source: .aiChat)
                turn.answer = String(repeating: "这是一段仅用于本地验证的无敏感文本。", count: 8); turn.status = .complete
                try await store.updateChat(turn)
            }
            let longChat = ChatViewModel(store: store, credentials: credentials, configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: StageEightTransport())
            await longChat.start(); panel.close()
            let longPanel = PanelController(inspirationViewModel: input, clipboardViewModel: clipboard, inspirationLibraryViewModel: library,
                globalSearchViewModel: search, dataDirectory: root, promptModel: prompts, chatModel: longChat)
            defer { longPanel.close() }
            longPanel.debugSetAutomaticDismissalEnabled(false); _ = longPanel.present(); _ = longPanel.showChat()
            _ = longPanel.debugPerformKeyEquivalent(keyCode: UInt16(kVK_DownArrow), modifiers: .command); try await settle()
            checks.append(("long_chat_first_page_bounded", longChat.turns.count == 50 && longChat.hasMore))
            longChat.followingLatest = false
            let position = longPanel.debugChatScrollOffset(set: 150) ?? -1000; longChat.scrollOffset = position
            longChat.draft = "继续时不要抢走滚动位置"; longChat.send(); try await wait { !longChat.busy }; try await settle()
            checks.append(("stream_does_not_steal_old_scroll", abs((longPanel.debugChatScrollOffset() ?? -2000) - position) < 5))
            longPanel.debugSelectClipboard(); _ = longPanel.showChat(); try await settle()
            checks.append(("tab_restores_exact_scroll", abs((longPanel.debugChatScrollOffset() ?? -2000) - position) < 5))
            try longPanel.debugCapturePromptPanel(to: output.appendingPathComponent("chat-long-scrolled.png"))
            let anchor = longChat.scrollAnchor, anchorOffset = longChat.scrollAnchorOffset
            longChat.loadMore(); try await wait { !longChat.loadingMore }; try await settle()
            // LazyVStack may realize an additional preceding row after insertion. Compare
            // the original row's measured viewport position, not the new first visible ID.
            let restoredOffset = anchor.flatMap { longChat.debugVisibleOffsets[$0] }
            print("JOTBLOOM_STAGE8_SCROLL anchor_id=\(anchor ?? -1) before_offset=\(anchorOffset) final_measured_offset=\(restoredOffset ?? -1000)")
            checks.append(("older_page_preserves_reading_anchor", restoredOffset != nil && abs((restoredOffset ?? -1000) - anchorOffset) < 5))
            var timings: [Double] = []
            for _ in 0..<100 { let began = ProcessInfo.processInfo.systemUptime; _ = try await store.chatPage(); timings.append((ProcessInfo.processInfo.systemUptime - began) * 1000) }
            timings.sort()
            var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let measured = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            } }
            print(String(format: "JOTBLOOM_STAGE8_SAMPLE turns=84 query_page=50 queries=100 p95_ms=%.3f max_ms=%.3f resident_mb=%.3f peak_resident_mb=%.3f", timings[94], timings[99], Double(info.resident_size)/1048576, Double(info.resident_size_max)/1048576))
            checks.append(("sample_page_p95_under_100ms", timings[94] < 100 && measured == KERN_SUCCESS))
            checks.append(("general_clipboard_untouched", NSPasteboard.general.changeCount == before))
            for check in checks { print("JOTBLOOM_STAGE8_SMOKE \(check.0)=\(check.1)") }
            print("JOTBLOOM_STAGE8_SMOKE screenshots=\(output.path) fixture=\(root.path) real_network=false real_keychain=false")
            fflush(stdout); exit(checks.allSatisfy(\.1) ? 0 : 1)
        } catch { print("JOTBLOOM_STAGE8_SMOKE failed=\(String(describing: type(of: error)))"); fflush(stdout); exit(1) }
    }
    private static func wait(_ test: () -> Bool) async throws {
        for _ in 0..<300 { if test() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw ChatError.busy
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 450_000_000) }
}
#endif
