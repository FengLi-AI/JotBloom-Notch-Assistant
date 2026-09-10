import AppKit
import Carbon.HIToolbox
import Combine
import JotBloomCore
import OSLog
import QuartzCore
import SwiftUI

@MainActor
final class PanelController: NSObject, PanelPresenting, NSWindowDelegate {
    var onRequestHide: (() -> Void)?

    private let logger = Logger(subsystem: "com.jotbloom.mengsheng", category: "panel")
    private let inspirationViewModel: InspirationInputViewModel
    private let clipboardViewModel: ClipboardHistoryViewModel
    private let inspirationLibraryViewModel: InspirationLibraryViewModel
    private let globalSearchViewModel: GlobalSearchViewModel
    private let panelState = PanelViewState()
    private let dataDirectory: URL?
    private let settingsModel: SettingsViewModel?
    private let promptModel: PromptLibraryViewModel?
    private let chatModel: ChatViewModel?
    var onChatCopy: (String) -> Bool = { _ in false }
    private var systemInteractionDepth = 0
    private var focusEventGeneration: UInt64 = 0
    private var restoringSystemFocus = false
    private var suspendedForDirectorySelection = false
    private var restoreAfterDirectorySelection = false
    private var closingVisual: NSWindow?
    private var frameAnimationTimer: Timer?
    private var currentMetrics: ScreenMetrics?
    private var expansionChangesAnimated = true
    private var detailTransitionInProgress = false
    private var promptPreviousExpansion = false
    private var cancellables: Set<AnyCancellable> = []
    private var shortcutEventMonitor: Any?
    private lazy var panel: JotBloomPanel = makePanel()
#if DEBUG
    private var automaticDismissalEnabled = true
#endif

    init(
        inspirationViewModel: InspirationInputViewModel,
        clipboardViewModel: ClipboardHistoryViewModel,
        inspirationLibraryViewModel: InspirationLibraryViewModel,
        globalSearchViewModel: GlobalSearchViewModel,
        dataDirectory: URL? = nil,
        settingsModel: SettingsViewModel? = nil,
        promptModel: PromptLibraryViewModel? = nil,
        chatModel: ChatViewModel? = nil
    ) {
        self.inspirationViewModel = inspirationViewModel
        self.clipboardViewModel = clipboardViewModel
        self.inspirationLibraryViewModel = inspirationLibraryViewModel
        self.globalSearchViewModel = globalSearchViewModel
        self.dataDirectory = dataDirectory
        self.settingsModel = settingsModel
        self.promptModel = promptModel
        self.chatModel = chatModel
        super.init()
        settingsModel?.onShortcutRecordingChanged = { [weak self] active in self?.setShortcutRecording(active) }
        chatModel?.onSystemInteraction = { [weak self] in self?.setSystemInteraction($0) }
        chatModel?.onAccepted = { [weak self] in
            guard let self, panelState.selectedTab == .chat, !panelState.isSettingsOpen else { return }
            if !panelState.isExpanded { panelState.expand() }
        }
        chatModel?.onOpenSettings = { [weak self] in
            self?.openSettings()
            self?.panelState.settingsSection = "ai"
        }
        promptModel?.onEditorOpened = { [weak self] in
            guard let self else { return }
            promptPreviousExpansion = panelState.isExpanded
            panelState.isPromptEditorOpen = true
            panelState.expand()
        }
        promptModel?.onEditorClosed = { [weak self] in
            guard let self else { return }
            panelState.isPromptEditorOpen = false
            if !promptPreviousExpansion { panelState.collapse() }
        }
        globalSearchViewModel.onOpenPrompt = { [weak self] id in
            guard let self else { return }
            requestSelectTab(.prompts)
            guard panelState.selectedTab == .prompts else { return }
            promptModel?.openEditor(id, returnName: "搜索结果", onReturn: { [weak self] in
                guard let self else { return }
                requestSelectTab(.globalSearch)
                globalSearchViewModel.refresh(preferredID: .init(source: .prompt, recordID: id))
                globalSearchViewModel.requestInputFocus()
            })
        }
        promptModel?.$feedback.compactMap { $0 }.sink { [weak self] message in
            guard let self, panelState.selectedTab == .clipboard else { return }
            clipboardViewModel.reportSaveFeedback(message)
        }.store(in: &cancellables)

        inspirationLibraryViewModel.onRequestExpand = { [weak self] in
            self?.panelState.expand()
        }
        inspirationLibraryViewModel.onDetailLoadFailure = {
            [weak self] identifier, message in
            self?.handleInspirationDetailLoadFailure(
                identifier: identifier,
                message: message
            )
        }
        globalSearchViewModel.onOpenInspiration = { [weak self] identifier in
            self?.openInspirationFromSearch(identifier: identifier)
        }

        panelState.$isExpanded
            .dropFirst()
            .sink { [weak self] isExpanded in
                self?.resizePanel(
                    expanded: isExpanded,
                    animated: self?.expansionChangesAnimated ?? false
                )
            }
            .store(in: &cancellables)

        panelState.$preferences.dropFirst().sink { [weak self] preferences in
            guard let self, preferences.reduceMotion else { return }
            resizePanel(expanded: panelState.isExpanded, animated: false)
            panel.alphaValue = 1
            closingVisual?.close()
            closingVisual = nil
        }.store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                panelState.objectWillChange.send()
                if panelState.reducesMotion {
                    resizePanel(expanded: panelState.isExpanded, animated: false)
                    panel.alphaValue = 1
                    closingVisual?.close()
                    closingVisual = nil
                }
            }.store(in: &cancellables)
    }

#if DEBUG
    var debugSettingsOpen: Bool { panelState.isSettingsOpen }
    func debugRunPlaceholderProbe(output: URL) async throws -> [(String, Bool)] {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_PLACEHOLDER_SMOKE"] == "1" else { return [] }
        var checks: [(String, Bool)] = []
        func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }
        debugSelectInspiration()
        // Let the previous search responder and the new editor finish mounting.
        try await Task.sleep(nanoseconds: 550_000_000)
        for expanded in [false, true] {
            debugSetExpanded(expanded)
            inspirationViewModel.text = ""
            inspirationViewModel.requestInputFocus()
            try await Task.sleep(nanoseconds: 550_000_000)
            let size = expanded ? "700" : "300"
            guard let editor = panel.firstResponder as? NSTextView else {
                checks.append(("placeholder_editor_focused_" + size, false)); continue
            }
            func capture(_ state: String) throws {
                try debugCapturePromptPanel(to: output.appendingPathComponent("placeholder-\(size)-\(state).png"))
            }
            checks.append(("empty_focused_" + size, editor.string.isEmpty && inspirationViewModel.text.isEmpty))
            try capture("focused-empty")
            panel.makeFirstResponder(nil); try await settle(); try capture("unfocused-empty")
            panel.makeFirstResponder(editor); try await settle(); try capture("refocused-empty")
            editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await settle()
            checks.append(("candidate_not_committed_" + size, editor.hasMarkedText() && inspirationViewModel.text.isEmpty))
            try capture("candidate")
            editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.unmarkText(); try await settle()
            checks.append(("candidate_cancel_empty_" + size, editor.string.isEmpty && !editor.hasMarkedText()))
            try capture("candidate-cancelled")
            editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0)); try await settle()
            checks.append(("committed_text_" + size, inspirationViewModel.text == "你好"))
            try capture("committed")
            inspirationViewModel.clearInput(); try await settle()
            checks.append(("clear_keeps_focus_" + size, editor.string.isEmpty && panel.firstResponder === editor))
            try capture("cleared")
            inspirationViewModel.undoClear(); try await settle()
            checks.append(("undo_restores_text_" + size, editor.string == "你好"))
            try capture("undo")
            editor.selectAll(nil); editor.insertText("A", replacementRange: editor.selectedRange()); try await settle()
            checks.append(("latin_text_" + size, inspirationViewModel.text == "A"))
            try capture("latin")
            editor.selectAll(nil); editor.deleteBackward(nil); try await settle()
            checks.append(("delete_to_empty_" + size, editor.string.isEmpty && inspirationViewModel.text.isEmpty))
            try capture("deleted")
        }
        return checks
    }
    /// Uses only the temporary models created by the Stage 10B harness.
    func debugRunTenCVisualProbe(output: URL) async throws -> [(String, Bool)] {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_STAGE10C_SMOKE"] == "1" else { return [] }
        let originalPreferences = panelState.preferences
        defer { panelState.preferences = originalPreferences }
        var checks: [(String, Bool)] = []
        func settle() async throws { try await Task.sleep(nanoseconds: 550_000_000) }
        func correctFrame(_ expanded: Bool) -> Bool {
            currentMetrics.map { panel.frame == PanelGeometry.panelFrame(for: $0, expanded: expanded)
                && panel.contentView?.bounds.height == panel.frame.height } ?? false
        }
        panelState.preferences.defaultSlot = .globalSearch
        dismiss(); _ = present(); try await settle()
        checks.append(("default_search_actual_expanded_frame", correctFrame(true) && panelState.selectedTab == .globalSearch))
        for index in 0..<10 {
            if index.isMultiple(of: 2) { panelState.collapse() } else { panelState.expand() }
            try await Task.sleep(nanoseconds: 35_000_000)
        }
        try await settle()
        checks.append(("ten_resize_reversals_settle", correctFrame(true) && frameAnimationTimer == nil))
        for _ in 0..<5 { dismiss(); _ = present(); try await Task.sleep(nanoseconds: 30_000_000) }
        try await settle()
        checks.append(("rapid_reopen_no_ghost", panel.isVisible && closingVisual == nil && correctFrame(true)))
        panelState.preferences.reduceMotion = true
        panelState.collapse()
        checks.append(("reduced_motion_compact_immediate", correctFrame(false) && frameAnimationTimer == nil))
        panelState.expand()
        checks.append(("reduced_motion_expanded_immediate", correctFrame(true) && frameAnimationTimer == nil))
        panelState.preferences.reduceMotion = false
        for tab: PanelTab in [.inspiration, .clipboard, .prompts, .inspirationLibrary] {
            requestSelectTab(tab)
            for expanded in [false, true] {
                if expanded { panelState.expand() } else { panelState.collapse() }
                try await settle()
                checks.append(("\(tab.rawValue)_\(expanded ? 700 : 300)_geometry", correctFrame(expanded)))
                try debugCapturePromptPanel(to: output.appendingPathComponent("10c-\(tab.rawValue)-\(expanded ? 700 : 300).png"))
            }
        }
        debugSendKeyDown(keyCode: UInt16(kVK_DownArrow)); try await settle()
        checks.append(("keyboard_reveals_focus", panelState.keyboardNavigation))
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: .init(x: 200, y: 100), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { panel.sendEvent(event) }
        checks.append(("mouse_hides_focus", !panelState.keyboardNavigation))
        openSettings(); try await settle()
        checks.append(("settings_expands", panelState.isSettingsOpen && correctFrame(true)))
        try debugCapturePromptPanel(to: output.appendingPathComponent("10c-settings-700.png"))
        closeSettings(); requestSelectTab(.inspiration); try await settle()
        inspirationViewModel.requestInputFocus(); try await settle()
        if let textView = panel.firstResponder as? NSTextView {
            textView.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            checks.append(("ime_candidate_present", textView.hasMarkedText()))
            _ = debugPerformKeyEquivalent(keyCode: UInt16(kVK_Escape))
            checks.append(("ime_escape_does_not_dismiss", panel.isVisible))
            debugClearMarkedText()
        } else { checks.append(("ime_editor_focused", false)) }
        var iconLoads = 0
        let cache = BloomApplicationIconCache { id in iconLoads += 1; return id == "known" ? NSImage(size: .init(width: 16, height: 16)) : nil }
        _ = cache.image(for: "known"); _ = cache.image(for: "known")
        _ = cache.image(for: "missing"); _ = cache.image(for: "missing")
        _ = cache.image(for: nil); _ = cache.image(for: "")
        checks.append(("source_icon_caches_hits_and_misses", iconLoads == 2))
        return checks
    }
    func debugOpenTenBInspiration(_ id: Int64) {
        requestSelectTab(.inspirationLibrary)
        openInspirationFromLibrary(identifier: id)
    }
    func debugSetExpanded(_ expanded: Bool) {
        if expanded { panelState.expand() } else { panelState.collapse() }
    }
    var debugSnapshot: (
        isVisible: Bool,
        isKey: Bool,
        textInputFocused: Bool,
        selectedTab: String,
        isExpanded: Bool,
        inspirationLibraryScreen: String,
        inspirationLibraryItemCount: Int,
        searchPhase: String,
        searchResultCount: Int,
        searchFocusRequest: Int,
        hasMarkedText: Bool,
        detailOrigin: String
    ) {
        (
            isVisible: panel.isVisible,
            isKey: panel.isKeyWindow,
            textInputFocused: panel.firstResponder is NSTextView,
            selectedTab: panelState.selectedTab.rawValue,
            isExpanded: panelState.isExpanded,
            inspirationLibraryScreen: String(
                describing: inspirationLibraryViewModel.screen
            ),
            inspirationLibraryItemCount: inspirationLibraryViewModel.items.count,
            searchPhase: String(describing: globalSearchViewModel.phase),
            searchResultCount: globalSearchViewModel.snapshot.allResults.count,
            searchFocusRequest: globalSearchViewModel.focusRequest,
            hasMarkedText: panel.debugHasMarkedText,
            detailOrigin: String(describing: panelState.inspirationDetailOrigin)
        )
    }

    func debugSelectClipboard() {
        requestSelectTab(.clipboard)
    }

    func debugSelectPrompts() { requestSelectTab(.prompts) }
    func debugChatInputProbe() -> [(String, Bool)] {
        func editor(in view: NSView) -> ChatTextView? {
            if let text = view as? ChatTextView { return text }
            for child in view.subviews { if let found = editor(in: child) { return found } }
            return nil
        }
        guard let content = panel.contentView, let text = editor(in: content) else { return [("chat_editor_found", false)] }
        let send = text.send, previous = text.string
        var sent = 0
        text.send = { sent += 1 }
        defer { text.send = send; text.string = previous; text.didChangeText() }
        func enter(_ flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            text.keyDown(with: event)
        }
        panel.makeFirstResponder(text)
        text.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        enter(); let markedSafe = sent == 0
        text.unmarkText(); text.string = "换行"; text.setSelectedRange(NSRange(location: 2, length: 0))
        enter(.shift); let newline = text.string.contains("\n") && sent == 0
        enter()
        return [("marked_enter_does_not_send", markedSafe), ("shift_enter_newline", newline), ("enter_sends_once", sent == 1)]
    }
    func debugChatScrollOffset(set value: CGFloat? = nil) -> CGFloat? {
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        guard let content = panel.contentView,
              let scroll = scrolls(content).max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }) else { return nil }
        if let value {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: value)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        return scroll.contentView.bounds.minY
    }
    func debugCapturePromptPanel(to url: URL) throws {
        guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SettingsError.responseInvalid }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SettingsError.responseInvalid }
        try png.write(to: url)
    }

    func debugSelectInspiration() {
        requestSelectTab(.inspiration)
    }

    func debugSelectInspirationLibrary() {
        requestSelectTab(.inspirationLibrary)
    }

    func debugSelectGlobalSearch() {
        requestSelectTab(.globalSearch)
    }

    @discardableResult
    func debugPerformKeyEquivalent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return false
        }
        return panel.performKeyEquivalent(with: event)
    }

    func debugSendKeyDown(keyCode: UInt16) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return
        }
        panel.sendEvent(event)
    }

    func debugClearMarkedText() {
        panel.debugClearMarkedText()
    }

    func debugSetAutomaticDismissalEnabled(_ enabled: Bool) {
        automaticDismissalEnabled = enabled
    }

    func debugSettingsProbe(output: URL) async throws -> Bool {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_STAGE6_SMOKE"] == "1", let settingsModel else { return false }
        automaticDismissalEnabled = false
        _ = present(); openSettings()
        try await Task.sleep(nanoseconds: 600_000_000)
        var passed = panelState.isSettingsOpen && panelState.isExpanded
        settingsModel.recordingShortcut = true
        debugSendKeyDown(keyCode: UInt16(kVK_Escape))
        passed = passed && !settingsModel.recordingShortcut && panelState.isSettingsOpen
        for section in ["general", "tabs", "clipboard", "storage", "ai"] {
            panelState.settingsSection = section
            try await Task.sleep(nanoseconds: 180_000_000)
            guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: output.appendingPathComponent(section + ".png")) }
            passed = passed && panelState.isExpanded && view.bounds.height > 300
        }
        closeSettings()
        passed = passed && !panelState.isSettingsOpen && !panelState.isExpanded
        dismiss()
        return passed
    }

    func debugShortcutRecordingProbe() async throws -> [(String, Bool)] {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_STAGE6_SMOKE"] == "1", let model = settingsModel else { return [] }
        var checks: [(String, Bool)] = []
        let original = model.value.shortcut
        let register = model.onShortcut
        defer {
            model.recordingShortcut = false
            model.onShortcut = { _ in true }; model.setShortcut(original)
            model.onShortcut = register
            closeSettings(); dismiss()
        }
        _ = present(); openSettings()
        try await Task.sleep(nanoseconds: 250_000_000)
        func send(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown, characters: String = " ") {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode) else { return }
            NSApp.sendEvent(event)
        }
        model.onShortcut = { _ in true }
        model.toggleShortcutRecording()
        try await Task.sleep(nanoseconds: 100_000_000)
        send(UInt16(kVK_Control), [.control], type: .flagsChanged, characters: "")
        checks.append(("recorder_modifier_preview", model.shortcutPreview == "⌃…" && model.recordingShortcut))
        send(UInt16(kVK_ANSI_K), [.control, .option], characters: "k")
        checks.append(("recorder_app_dispatch_saves_combination", !model.recordingShortcut && model.value.shortcut.keyCode == 40 && model.value.shortcut.modifiers == UInt32(controlKey | optionKey)))
        let accepted = model.value.shortcut
        model.onShortcut = { _ in false }
        model.toggleShortcutRecording()
        send(UInt16(kVK_ANSI_J), [.command, .option], characters: "j")
        checks.append(("recorder_conflict_feedback_retains_previous", model.recordingShortcut && model.value.shortcut == accepted && model.feedback?.contains("无法注册") == true))
        send(UInt16(kVK_Space), [.shift])
        checks.append(("recorder_shift_only_feedback", model.recordingShortcut && model.feedback == SettingsError.invalidShortcut.localizedDescription && model.value.shortcut == accepted))
        send(UInt16(kVK_Space), [.command])
        checks.append(("recorder_reserved_command_space_retained", model.recordingShortcut && model.value.shortcut == accepted))
        send(UInt16(kVK_Escape), [])
        checks.append(("recorder_escape_only_cancels", !model.recordingShortcut && shortcutEventMonitor == nil && panelState.isSettingsOpen))
        model.onShortcut = { _ in true }
        model.toggleShortcutRecording()
        send(UInt16(kVK_ANSI_K), [.command, .option], characters: "k")
        checks.append(("recorder_command_event_before_menu", !model.recordingShortcut && model.value.shortcut.modifiers == UInt32(cmdKey | optionKey)))
        model.toggleShortcutRecording(); model.leaveSettings()
        checks.append(("recorder_leaving_removes_monitor", shortcutEventMonitor == nil && !model.recordingShortcut))
        return checks
    }

    func debugStageNineSettings(section: String) {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_STAGE9_SMOKE"] == "1" else { return }
        openSettings(); panelState.settingsSection = section
    }

    /// Isolated regression evidence for folder handoff, first-render controls and IME.
    func debugSettingsFixesProbe(output: URL) async throws -> [(String, Bool)] {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_STAGE6_SMOKE"] == "1", let settingsModel else { return [] }
        var checks: [(String, Bool)] = []
        automaticDismissalEnabled = false
        settingsModel.onSystemInteraction = { [weak self] in self?.setSystemInteraction($0) }
        settingsModel.onDirectorySelection = { [weak self] in self?.setDirectorySelection($0) }
        defer {
            settingsModel.endDirectorySelection()
            settingsModel.onSystemInteraction = nil
            settingsModel.onDirectorySelection = nil
            dismiss()
        }
        func snapshot(_ name: String) throws {
            guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }

        // Enter and re-enter without clicking any settings control.
        panelState.settingsSection = "general"
        for attempt in 1...2 {
            _ = present(); openSettings()
            try await Task.sleep(nanoseconds: 550_000_000)
            try snapshot("fix-settings-entry-\(attempt)")
            checks.append(("settings_entry_\(attempt)_expanded", panelState.isSettingsOpen && panelState.isExpanded && panelState.settingsSection == "general"))
            if attempt == 1 { dismiss() }
        }
        panelState.settingsSection = "storage"
        try await Task.sleep(nanoseconds: 100_000_000)
        let originalFrame = panel.frame
        let picker = SettingsControls.makeDirectoryPicker()
        picker.directoryURL = output
        checks.append(("directory_picker_allows_new_folder", picker.canCreateDirectories && picker.canChooseDirectories && !picker.canChooseFiles && !picker.allowsMultipleSelection))
        checks.append(("directory_handoff_hides_without_reset", settingsModel.beginDirectorySelection() && !panel.isVisible && panelState.isSettingsOpen && panelState.settingsSection == "storage"))
        checks.append(("directory_handoff_reentry_blocked", !settingsModel.beginDirectorySelection() && settingsModel.blocksPanelInteraction && !present()))
        // A separate system task finishing must not bring the hidden panel forward.
        setSystemInteraction(true); setSystemInteraction(false)
        checks.append(("directory_handoff_ignores_other_completion", !panel.isVisible))
        var pickerVisibleWithoutOverlay = false
        let cancelled: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            picker.begin { continuation.resume(returning: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pickerVisibleWithoutOverlay = picker.isVisible && !self.panel.isVisible
                picker.cancel(nil)
            }
        }
        checks.append(("native_directory_picker_visible_without_overlay", pickerVisibleWithoutOverlay))
        settingsModel.endDirectorySelection()
        try await Task.sleep(nanoseconds: 120_000_000)
        checks.append(("directory_cancel_restores_exact_settings", cancelled == .cancel && panel.isVisible && panel.isKeyWindow && panel.frame == originalFrame && panelState.settingsSection == "storage" && panelState.isSettingsOpen && !settingsModel.blocksPanelInteraction && systemInteractionDepth == 0))
        try snapshot("fix-directory-return")
        settingsModel.endDirectorySelection()
        checks.append(("directory_completion_idempotent", systemInteractionDepth == 0 && panel.isVisible))

        // Exercise the real SwiftUI .task lifecycle on initial entry and app-like reentry.
        for attempt in 1...3 {
            panelState.settingsSection = "ai"
            try await Task.sleep(nanoseconds: 150_000_000)
            if attempt == 3 { try snapshot("ai-no-keychain-read") }
            dismiss(); _ = present(); openSettings()
            try await Task.sleep(nanoseconds: 550_000_000)
        }

        closeSettings(); debugSelectInspiration()
        inspirationViewModel.text = ""
        inspirationViewModel.requestInputFocus()
        try await Task.sleep(nanoseconds: 500_000_000)
        checks.append(("empty_editor_focused", panel.firstResponder is NSTextView))
        try snapshot("fix-input-focused-empty")
        if let editor = panel.firstResponder as? NSTextView {
            editor.setMarkedText("adife", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(nanoseconds: 100_000_000)
            checks.append(("ime_marked_text_preserved", editor.hasMarkedText()))
            try snapshot("fix-input-composing")
            editor.insertText("灵感测试", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(nanoseconds: 100_000_000)
            checks.append(("ime_commit_updates_binding", !editor.hasMarkedText() && inspirationViewModel.text == "灵感测试"))
            inspirationViewModel.text = ""
            panel.makeFirstResponder(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            try snapshot("fix-input-unfocused-empty")
        } else {
            checks.append(("ime_marked_text_preserved", false))
        }
        return checks
    }

    /// Unlike the visual probes, this regression MUST run with automatic dismissal enabled.
    func debugAuthorizationFocusProbe(startTest: () -> Void) async throws -> [(String, Bool)] {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_STAGE6_SMOKE"] == "1", let settingsModel else { return [] }
        let originalHide = onRequestHide
        var hideRequests = 0
        onRequestHide = { [weak self] in
            hideRequests += 1
            self?.dismiss()
            settingsModel.leaveSettings()
        }
        settingsModel.onSystemInteraction = { [weak self] in self?.setSystemInteraction($0) }
        defer {
            automaticDismissalEnabled = false
            onRequestHide = originalHide
            settingsModel.onSystemInteraction = nil
            dismiss()
        }
        _ = present(); openSettings(); panelState.settingsSection = "ai"
        try await Task.sleep(nanoseconds: 550_000_000)
        automaticDismissalEnabled = true
        startTest()
        for _ in 0..<150 {
            if settingsModel.readingCredential { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        // Two simulated authorization windows take and return key-window status.
        for _ in 0..<2 {
            panel.resignKey()
            try await Task.sleep(nanoseconds: 10_000_000)
            panel.makeKey()
        }
        var checks = [("authorization_focus_two_handoffs_no_hide", hideRequests == 0 && panel.isVisible)]
        for _ in 0..<200 {
            if !settingsModel.readingCredential { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        // Notification delivery may lag behind the window's actual key state.
        windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        try await Task.sleep(nanoseconds: 20_000_000)
        checks.append(("authorization_to_network_handoff_not_cancelled", hideRequests == 0 && panel.isVisible && !settingsModel.testing.isEmpty))
        for _ in 0..<300 {
            if settingsModel.testing.isEmpty { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        try await Task.sleep(nanoseconds: 30_000_000)
        checks.append(("authorization_result_visible_after_late_resign", panel.isVisible && panel.isKeyWindow && hideRequests == 0 && settingsModel.connectionStatus[.main]?.hasPrefix("连接成功") == true && systemInteractionDepth == 0))
        // A dismissal queued before an operation starts must not survive that operation.
        panel.resignKey()
        setSystemInteraction(true)
        panel.makeKey()
        setSystemInteraction(false)
        try await Task.sleep(nanoseconds: 30_000_000)
        checks.append(("queued_pre_authorization_resign_invalidated", panel.isVisible && hideRequests == 0))
        setSystemInteraction(true); setSystemInteraction(true)
        panel.resignKey()
        setSystemInteraction(false)
        try await Task.sleep(nanoseconds: 20_000_000)
        checks.append(("nested_authorization_keeps_focus_guard", panel.isVisible && hideRequests == 0 && systemInteractionDepth == 1))
        setSystemInteraction(false)
        try await Task.sleep(nanoseconds: 30_000_000)
        checks.append(("focus_guard_released_after_actual_key_return", panel.isKeyWindow && !restoringSystemFocus && systemInteractionDepth == 0))
        // A genuine later focus loss must still dismiss: the protection cannot become sticky.
        panel.resignKey()
        try await Task.sleep(nanoseconds: 40_000_000)
        checks.append(("ordinary_focus_loss_still_dismisses", hideRequests == 1 && !panel.isVisible))
        _ = present(); openSettings(); panelState.settingsSection = "ai"
        try await Task.sleep(nanoseconds: 550_000_000)
        startTest()
        for _ in 0..<150 {
            if settingsModel.readingCredential { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        // Explicit dismissal is different from a system focus handoff: preserve cancellation.
        dismiss(); settingsModel.leaveSettings()
        try await Task.sleep(nanoseconds: 350_000_000)
        checks.append(("explicit_close_during_auth_does_not_resurrect", !panel.isVisible && settingsModel.testing.isEmpty && !settingsModel.readingCredential && systemInteractionDepth == 0))
        return checks
    }

    /// Runs only inside the existing isolated Stage 5 harness, never against user data.
    func debugRunInterfaceProbe() async throws -> Bool {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_STAGE5_SMOKE"] == "1" else { return false }
        let originalPreferences = panelState.preferences
        defer { panelState.preferences = originalPreferences; dismiss() }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("jotbloom-native-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks: [(String, Bool)] = []
        func settle() async { try? await Task.sleep(nanoseconds: 550_000_000) }
        func capture(_ name: String) throws {
            guard let view = panel.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if name == "input-300" {
                checks.append(("square_top_rounded_bottom", (bitmap.colorAt(x: 2, y: 2)?.alphaComponent ?? 0) > 0.99
                    && (bitmap.colorAt(x: 2, y: bitmap.pixelsHigh - 3)?.alphaComponent ?? 1) < 0.1))
            }
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent(name + ".png"))
            }
        }
        panelState.preferences = PanelPreferences(defaultSlot: .inspirationLibrary)
        _ = present()
        await settle()
        checks.append(("default_library", panelState.selectedTab == .inspirationLibrary && !panelState.isExpanded))
        checks.append(("library_default_focus_hidden", !panelState.keyboardNavigation && panel.firstResponder is ListKeyboardResponder))
        try capture("library-300")
        let previousSelection = inspirationLibraryViewModel.selectedID
        debugSendKeyDown(keyCode: UInt16(kVK_DownArrow))
        await settle()
        checks.append(("library_keyboard_focus", panelState.keyboardNavigation && panel.firstResponder is ListKeyboardResponder))
        checks.append(("library_keyboard_selection", inspirationLibraryViewModel.selectedID != previousSelection))
        try capture("library-keyboard-300")
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 200, y: 100),
                                         modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: panel.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 0, pressure: 0) {
            panel.sendEvent(event)
        }
        await settle()
        checks.append(("pointer_hides_focus_keeps_navigation", !panelState.keyboardNavigation && panel.firstResponder is ListKeyboardResponder))
        try capture("library-pointer-300")
        panel.makeFirstResponder(nil)
        debugSendKeyDown(keyCode: UInt16(kVK_UpArrow))
        await settle()
        checks.append(("arrow_restores_list_responder", panelState.keyboardNavigation && panel.firstResponder is ListKeyboardResponder))
        openSettings()
        await settle()
        checks.append(("settings_expands", panelState.isSettingsOpen && panelState.isExpanded))
        try capture("settings-general-700")
        let count = inspirationLibraryViewModel.items.count
        _ = debugPerformKeyEquivalent(keyCode: UInt16(kVK_Delete), modifiers: .command)
        _ = debugPerformKeyEquivalent(keyCode: UInt16(kVK_UpArrow), modifiers: .command)
        checks.append(("settings_keyboard_isolated", count == inspirationLibraryViewModel.items.count && panelState.isExpanded))
        panelState.settingsSection = "tabs"
        await settle()
        try capture("settings-tabs-700")
        _ = debugPerformKeyEquivalent(keyCode: UInt16(kVK_Escape))
        await settle()
        checks.append(("settings_restores_compact_route", !panelState.isSettingsOpen && !panelState.isExpanded && panelState.selectedTab == .inspirationLibrary))
        panelState.expand()
        await settle()
        try capture("library-700")
        if let item = inspirationLibraryViewModel.items.first {
            openInspirationFromLibrary(identifier: item.id)
            await settle()
            let editedBody = inspirationLibraryViewModel.detailBody + "\nUI 设置往返保存验证"
            inspirationLibraryViewModel.detailBody = editedBody
            openSettings()
            await settle()
            checks.append(("detail_flush_before_settings", panelState.isSettingsOpen && !inspirationLibraryViewModel.isSavingText))
            closeSettings()
            await settle()
            checks.append(("detail_restored", isInspirationDetailVisible && inspirationLibraryViewModel.detailBody == editedBody))
            try capture("detail-700")
            returnFromInspirationDetail()
            await settle()
        } else { checks.append(("detail_fixture_available", false)) }
        for _ in 0..<5 { panelState.preferences.move(.globalSearch, by: -1) }
        _ = debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)
        await settle()
        checks.append(("shortcut_follows_order", panelState.selectedTab == .globalSearch))
        checks.append(("prompt_slot_available", debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_4), modifiers: .command) && panelState.selectedTab == .prompts))
        checks.append(("chat_slot_disabled", !debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_6), modifiers: .command)))
        _ = debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)
        globalSearchViewModel.query = "stage5-shared"
        await settle()
        try capture("search-700")
        openSettings()
        _ = debugPerformKeyEquivalent(keyCode: UInt16(kVK_ANSI_F), modifiers: .command)
        checks.append(("command_f_exits_settings", !panelState.isSettingsOpen && panelState.selectedTab == .globalSearch))
        panelState.preferences = PanelPreferences(reduceMotion: true)
        dismiss()
        _ = present()
        panelState.expand()
        if let metrics = currentMetrics {
            checks.append(("reduced_motion_immediate_frame", panel.frame == PanelGeometry.panelFrame(for: metrics, expanded: true)))
        }
        panelState.preferences.reduceMotion = false
        for _ in 0..<4 {
            panelState.expand()
            try? await Task.sleep(nanoseconds: 25_000_000)
            dismiss()
            _ = present()
        }
        await settle()
        checks.append(("rapid_toggle_no_stale_close", panel.isVisible && closingVisual == nil))
        panelState.expand()
        try? await Task.sleep(nanoseconds: 40_000_000)
        panelState.collapse()
        try? await Task.sleep(nanoseconds: 30_000_000)
        panelState.expand()
        try? await Task.sleep(nanoseconds: 50_000_000)
        panelState.collapse()
        inspirationViewModel.text = "让灵感有一个随手落下的地方\n先记下，再慢慢整理。"
        await settle()
        checks.append(("settled_compact_geometry", currentMetrics.map {
            panel.frame == PanelGeometry.panelFrame(for: $0)
                && panel.contentView?.bounds.height == panel.frame.height
        } ?? false))
        try capture("input-300")
        panelState.expand()
        await settle()
        try capture("input-700")
        for expanded in [true, false] {
            if expanded { panelState.expand() } else { panelState.collapse() }
            inspirationViewModel.text = ""
            inspirationViewModel.requestInputFocus()
            await settle()
            let height = expanded ? "700" : "300"
            checks.append(("empty_input_font_" + height,
                           (panel.firstResponder as? NSTextView)?.font?.pointSize == (expanded ? 15 : 14)))
            try capture("input-placeholder-" + height)
            inspirationViewModel.text = "有什么想法，先记下来…"
            await settle()
            try capture("input-baseline-" + height)
        }
        requestSelectTab(.clipboard)
        panelState.expand()
        await settle()
        try capture("clipboard-700")
        panelState.collapse()
        await settle()
        try capture("clipboard-300")
        debugSendKeyDown(keyCode: UInt16(kVK_DownArrow))
        await settle()
        checks.append(("clipboard_keyboard_focus", panelState.keyboardNavigation && panel.firstResponder is ListKeyboardResponder))
        try capture("clipboard-keyboard-300")
        dismiss()
        _ = present()
        await settle()
        checks.append(("reopen_resets_keyboard_hint", !panelState.keyboardNavigation))
        print("JOTBLOOM_UI_SMOKE " + checks.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
              + " captures=\(output.path)")
        return checks.allSatisfy(\.1)
    }
#endif

    var isPanelKeyWindow: Bool {
        panel.isKeyWindow
    }

    @discardableResult
    func present() -> Bool {
        guard !suspendedForDirectorySelection else { return false }
        focusEventGeneration &+= 1
        restoringSystemFocus = false
        guard let screen = ScreenLocator.screenUnderMouse() else {
            logger.error("Panel presentation skipped because no screen is available")
            return false
        }

        let metrics = ScreenLocator.metrics(for: screen)
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        currentMetrics = metrics
        expansionChangesAnimated = false
        panelState.resetForPresentation()
        panelState.update(metrics: metrics)
        expansionChangesAnimated = true

        closingVisual?.close()
        closingVisual = nil
        let finalFrame = PanelGeometry.panelFrame(for: metrics, expanded: panelState.isExpanded)
        panel.alphaValue = panelState.reducesMotion ? 1 : 0
        panel.setFrame(panelState.reducesMotion ? finalFrame : finalFrame.offsetBy(dx: 0, dy: 8), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        completeTabSelection(panelState.selectedTab)
        if !panelState.reducesMotion {
            animatePanel(to: finalFrame, duration: 0.46, curve: (0.18, 0.88, 0.24, 1.035), fadeIn: true)
        }

        logger.debug("Panel presented on a \(Int(screen.frame.width), privacy: .public) by \(Int(screen.frame.height), privacy: .public) point screen")
        return true
    }

    func prepareForDismissal() -> Bool {
        guard settingsModel?.confirmingClear != true else { return false }
        guard settingsModel?.allowLeavingPrompt() != false, chatModel?.canLeaveChat() != false else { return false }
        guard chatModel?.confirmingDelete != true else { return false }
        chatModel?.cancelAuthorization()
        guard !clipboardViewModel.confirmingClear, !clipboardViewModel.isClearing else { return false }
        guard promptModel?.flushEdit() != false else { return false }
        if promptModel?.detailID != nil { return promptModel?.closeEditor() ?? true }
        return true
    }

    func dismiss() {
        // Directory selection preserves the route, scroll position and expanded size.
        guard !suspendedForDirectorySelection else { return }
        guard prepareForDismissal() else { return }
        settingsModel?.recordingShortcut = false
        promptModel?.panelDismissed()
        focusEventGeneration &+= 1
        restoringSystemFocus = false
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        animateDismissalVisual()
        detailTransitionInProgress = false
        inspirationLibraryViewModel.resetForPanelDismissal()
        globalSearchViewModel.resetForPanelDismissal()
        panel.orderOut(nil)
        expansionChangesAnimated = false
        panelState.resetForPresentation()
        expansionChangesAnimated = true
        logger.debug("Panel dismissed")
    }

    func close() {
        settingsModel?.recordingShortcut = false
        setShortcutRecording(false)
        focusEventGeneration &+= 1
        restoringSystemFocus = false
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        closingVisual?.close()
        panel.delegate = nil
        panel.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel, !panel.isKeyWindow, settingsModel?.recordingShortcut == true {
            settingsModel?.recordingShortcut = false
            settingsModel?.feedback = "录制已取消：键盘焦点离开了萌生。若组合被系统接收，请重新录制其他组合，例如 ⌃⌥K。"
        }
        guard notification.object as? NSWindow === panel,
              panel.isVisible, !panel.isKeyWindow, systemInteractionDepth == 0,
              !restoringSystemFocus, settingsModel?.maintaining != true else { return }
#if DEBUG
        guard automaticDismissalEnabled else { return }
#endif
        let expected = focusEventGeneration
        DispatchQueue.main.async { [weak self] in
            // A queued resign is obsolete once focus returned or a system operation started.
            guard let self, focusEventGeneration == expected,
                  panel.isVisible, !panel.isKeyWindow, systemInteractionDepth == 0,
                  !restoringSystemFocus, settingsModel?.maintaining != true else { return }
            self.onRequestHide?()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        focusEventGeneration &+= 1
        finishSystemFocusRestorationIfKey()
    }

    func setSystemInteraction(_ active: Bool) {
        guard active || systemInteractionDepth > 0 else { return }
        focusEventGeneration &+= 1
        systemInteractionDepth = max(0, systemInteractionDepth + (active ? 1 : -1))
        guard systemInteractionDepth == 0, !suspendedForDirectorySelection, panel.isVisible else { return }
        restoringSystemFocus = true
        let expected = focusEventGeneration
        // Let the system dialog unwind first. Releasing the guard before making key
        // lets its delayed resign notification dismiss this nonactivating panel.
        DispatchQueue.main.async { [weak self] in
            guard let self, focusEventGeneration == expected, systemInteractionDepth == 0,
                  panel.isVisible, !suspendedForDirectorySelection else { return }
            if !panel.isKeyWindow { NSApp.activate(ignoringOtherApps: true) }
            panel.makeKeyAndOrderFront(nil)
            finishSystemFocusRestorationIfKey()
        }
    }

    private func finishSystemFocusRestorationIfKey() {
        guard restoringSystemFocus else { return }
        let expected = focusEventGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, focusEventGeneration == expected, systemInteractionDepth == 0,
                  panel.isVisible, panel.isKeyWindow else { return }
            restoringSystemFocus = false
        }
    }

    func setDirectorySelection(_ active: Bool) {
        guard active != suspendedForDirectorySelection else { return }
        suspendedForDirectorySelection = active
        if active {
            restoreAfterDirectorySelection = panel.isVisible
            frameAnimationTimer?.invalidate()
            frameAnimationTimer = nil
            closingVisual?.close()
            closingVisual = nil
            panel.orderOut(nil)
        } else if restoreAfterDirectorySelection {
            restoreAfterDirectorySelection = false
            // Do not call present(): it resets the current settings page and size.
            resizePanel(expanded: panelState.isExpanded, animated: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    private func makePanel() -> JotBloomPanel {
        let panel = JotBloomPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.onSettingsKey = { [weak self] event in self?.handleSettingsKey(event) ?? false }
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.tabbingMode = .disallowed
        panel.animationBehavior = .none
        panel.delegate = self
        panel.acceptsMouseMovedEvents = true
        panel.onKeyboardInteraction = { [weak self] in self?.panelState.useKeyboardNavigation() }
        panel.onPointerInteraction = { [weak self] in self?.panelState.usePointerNavigation() }
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if promptModel?.editingID != nil { promptModel?.cancelEdit(); return }
            if promptModel?.detailID != nil, !panelState.isSettingsOpen {
                _ = promptModel?.returnFromDetail(); return
            }
            if panelState.isSettingsOpen {
                closeSettings()
            } else if isInspirationDetailVisible {
                returnFromInspirationDetail()
            } else {
                onRequestHide?()
            }
        }
        panel.onSaveInspiration = { [weak self] in
            self?.inspirationViewModel.save()
        }
        panel.onDiscuss = { [weak self] in self?.inspirationViewModel.discuss() }
        panel.isChatActive = { [weak self] in
            self?.panelState.selectedTab == .chat && self?.panelState.isSettingsOpen == false
        }
        panel.onNewChat = { [weak self] in self?.chatModel?.requestNew() }
        panel.onSaveChatSummary = { [weak self] in
            guard let chat = self?.chatModel else { return }
            if chat.summaryPreview { chat.saveSummary() } else { chat.summarize() }
        }
        panel.onSaveInspirationDetail = { [weak self] in
            self?.inspirationLibraryViewModel.commandSave()
        }
        panel.onExpand = { [weak self] in self?.panelState.expand() }
        panel.onCollapse = { [weak self] in
            guard self?.promptModel?.detailID == nil else { return }
            self?.panelState.collapse()
        }
        panel.isClipboardActive = { [weak self] in
            (self?.panelState.selectedTab == .clipboard || (self?.panelState.selectedTab == .prompts && self?.promptModel?.editingID == nil && self?.promptModel?.detailID == nil))
                && self?.panelState.isSettingsOpen == false && self?.clipboardViewModel.confirmingClear == false
        }
        panel.isInspirationActive = { [weak self] in
            self?.panelState.selectedTab == .inspiration
                && self?.panelState.isSettingsOpen == false && self?.clipboardViewModel.confirmingClear == false
        }
        panel.isInspirationLibraryListActive = { [weak self] in
            self?.panelState.selectedTab == .inspirationLibrary
                && self?.panelState.isSettingsOpen == false && self?.clipboardViewModel.confirmingClear == false
                && self?.isInspirationDetailVisible == false
        }
        panel.isInspirationLibraryDetailActive = { [weak self] in
            self?.isInspirationDetailVisible == true
        }
        panel.isGlobalSearchActive = { [weak self] in
            self?.panelState.selectedTab == .globalSearch
                && self?.panelState.isSettingsOpen == false && self?.clipboardViewModel.confirmingClear == false
                && self?.isInspirationDetailVisible == false
        }
        panel.onSelectInspiration = { [weak self] in
            self?.requestSelectTab(.inspiration)
        }
        panel.onSelectClipboard = { [weak self] in
            self?.requestSelectTab(.clipboard)
        }
        panel.onSelectInspirationLibrary = { [weak self] in
            self?.requestSelectTab(.inspirationLibrary)
        }
        panel.onSelectGlobalSearch = { [weak self] in
            self?.requestSelectTab(.globalSearch)
        }
        panel.onSettings = { [weak self] in self?.toggleSettings() }
        panel.onSelectSlot = { [weak self] index in
            guard let self, panelState.preferences.order.indices.contains(index),
                  let tab = PanelTab(rawValue: panelState.preferences.order[index].rawValue) else { return false }
            requestSelectTab(tab)
            return true
        }
        panel.onMoveClipboardSelection = { [weak self] offset in
            if self?.panelState.selectedTab == .prompts { self?.promptModel?.moveSelection(by: offset); return }
            self?.clipboardViewModel.moveSelection(by: offset)
            self?.clipboardViewModel.requestListFocus()
        }
        panel.onActivateClipboardSelection = { [weak self] in
            if self?.panelState.selectedTab == .prompts { self?.promptModel?.openSelected(); return }
            self?.clipboardViewModel.copySelected(collapseAfterCopy: true)
        }
        panel.onCopyClipboardSelection = { [weak self] in
            if self?.panelState.selectedTab == .prompts { self?.promptModel?.copySelected(collapse: false); return }
            self?.clipboardViewModel.copySelected(collapseAfterCopy: false)
        }
        panel.onDeleteClipboardSelection = { [weak self] in
            if self?.panelState.selectedTab == .prompts { self?.promptModel?.deleteSelected(); return }
            self?.clipboardViewModel.deleteSelected()
        }
        panel.onUndoClipboardDeletion = { [weak self] in
            if self?.panelState.selectedTab == .prompts { self?.promptModel?.undoDeletion(); return }
            self?.clipboardViewModel.undoDeletion()
        }
        panel.onMoveInspirationSelection = { [weak self] offset in
            self?.inspirationLibraryViewModel.moveSelection(by: offset)
            self?.inspirationLibraryViewModel.requestListFocus()
        }
        panel.onOpenInspirationSelection = { [weak self] in
            self?.openSelectedLibraryInspiration()
        }
        panel.onDeleteInspirationSelection = { [weak self] in
            self?.inspirationLibraryViewModel.deleteSelected()
        }
        panel.onUndoInspirationDeletion = { [weak self] in
            self?.inspirationLibraryViewModel.undoDeletion()
        }
        panel.onMoveSearchSelection = { [weak self] offset in
            self?.globalSearchViewModel.moveSelection(by: offset)
        }
        panel.onActivateSearchSelection = { [weak self] in
            self?.globalSearchViewModel.activateSelected()
        }
        panel.onCopySearchSelection = { [weak self] in
            self?.globalSearchViewModel.copySelectedWithoutCollapsing() ?? false
        }
        panel.onQuit = { NSApp.terminate(nil) }

        let materialView = PanelMaterialView(frame: .zero)

        let hostingView = NSHostingView(
            rootView: PanelRootView(
                panelState: panelState,
                inspirationViewModel: inspirationViewModel,
                clipboardViewModel: clipboardViewModel,
                inspirationLibraryViewModel: inspirationLibraryViewModel,
                globalSearchViewModel: globalSearchViewModel,
                onSelectTab: { [weak self] tab in
                    self?.requestSelectTab(tab)
                },
                onOpenLibraryInspiration: { [weak self] identifier in
                    self?.openInspirationFromLibrary(identifier: identifier)
                },
                onReturnFromInspirationDetail: { [weak self] in
                    self?.returnFromInspirationDetail()
                },
                onSettings: { [weak self] in self?.toggleSettings() },
                onCloseSettings: { [weak self] in self?.closeSettings() },
                dataDirectory: dataDirectory,
                settingsModel: settingsModel,
                promptModel: promptModel,
                chatModel: chatModel,
                onChatCopy: { [weak self] in self?.onChatCopy($0) ?? false }
            )
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        // SwiftUI's outgoing 700pt settings layout must not impose a stale window minimum.
        hostingView.sizingOptions = []
        materialView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: materialView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor)
        ])

        panel.contentView = materialView
        return panel
    }

    private func setShortcutRecording(_ active: Bool) {
        if let shortcutEventMonitor {
            NSEvent.removeMonitor(shortcutEventMonitor)
            self.shortcutEventMonitor = nil
        }
        guard active else { return }
        // An explicit recording action must own keyboard focus, even in a nonactivating panel.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel)
        shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.panel.isKeyWindow, self.panelState.isSettingsOpen,
                  self.settingsModel?.recordingShortcut == true,
                  event.window == nil || event.window === self.panel else { return event }
            // Capture before the SwiftUI responder or application menu consumes the combination.
            return self.handleSettingsKey(event) ? nil : event
        }
    }

    private func handleSettingsKey(_ event: NSEvent) -> Bool {
        if chatModel?.confirmingDelete == true {
            if event.keyCode == UInt16(kVK_Escape) { chatModel?.confirmingDelete = false; return true }
            return event.keyCode != UInt16(kVK_Tab) && event.keyCode != UInt16(kVK_Return) && event.keyCode != UInt16(kVK_Space)
        }
        if clipboardViewModel.confirmingClear || clipboardViewModel.isClearing {
            if event.keyCode == UInt16(kVK_Escape), !clipboardViewModel.isClearing { clipboardViewModel.confirmingClear = false; return true }
            // Let Tab/Return activate the dialog's own Buttons, never list commands.
            if event.keyCode == UInt16(kVK_Tab) || event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_Space) { return false }
            return true
        }
        guard let settingsModel else { return false }
        if settingsModel.maintaining { return true }
        guard settingsModel.recordingShortcut,
              event.type == .keyDown || event.type == .flagsChanged else { return false }
        if event.keyCode == UInt16(kVK_Escape) { settingsModel.recordingShortcut = false; return true }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var carbon: UInt32 = 0
        var label = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
        if event.type == .flagsChanged {
            settingsModel.shortcutPreview = label.isEmpty ? "请按下组合键…" : label + "…"
            return true
        }
        if event.isARepeat { return true }
        let specialNames: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        let name = specialNames[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "Key \(event.keyCode)"
        settingsModel.shortcutPreview = label + name
        settingsModel.setShortcut(Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbon, label: label + name))
        return true
    }

    func showChat() -> Bool {
        requestSelectTab(.chat)
        return panelState.selectedTab == .chat && !panelState.isSettingsOpen
    }

    private func requestSelectTab(_ tab: PanelTab) {
        guard settingsModel?.allowLeavingPrompt() != false, chatModel?.canLeaveChat() != false else { return }
        guard chatModel?.confirmingDelete != true else { return }
        if tab != panelState.selectedTab { chatModel?.cancelAuthorization() }
        guard !clipboardViewModel.confirmingClear, !clipboardViewModel.isClearing else { return }
        guard promptModel?.flushEdit() != false else { return }
        if tab != .prompts, promptModel?.detailID != nil { _ = promptModel?.closeEditor() }
        if panelState.selectedTab == .prompts, tab != .prompts { promptModel?.panelDismissed() }
        guard settingsModel?.maintaining != true else { return }
        guard !detailTransitionInProgress else { return }
        if panelState.isSettingsOpen { panelState.closeSettings() }

        if isInspirationDetailVisible {
            if panelState.selectedTab == tab {
                if tab == .globalSearch {
                    returnFromInspirationDetail()
                } else {
                    inspirationLibraryViewModel.activate()
                }
                return
            }
            detailTransitionInProgress = true
            inspirationLibraryViewModel.flushBeforeTabChange {
                [weak self] succeeded in
                guard let self else { return }
                detailTransitionInProgress = false
                guard succeeded else { return }
                completeTabSelection(tab)
            }
            return
        }

        if panelState.selectedTab == tab {
            switch tab {
            case .inspiration:
                inspirationViewModel.requestInputFocus()
            case .clipboard:
                clipboardViewModel.requestListFocus()
            case .prompts:
                promptModel?.activate()
            case .chat:
                chatModel?.focus()
            case .inspirationLibrary:
                activateInspirationLibraryForCurrentRoute()
            case .globalSearch:
                panelState.expand()
                globalSearchViewModel.activate()
            }
            return
        }
        completeTabSelection(tab)
    }

    private func completeTabSelection(_ tab: PanelTab) {
        panelState.select(tab)
        switch tab {
        case .inspiration:
            inspirationViewModel.refreshRecentInspirations()
            inspirationViewModel.requestInputFocus()
        case .clipboard:
            clipboardViewModel.requestListFocus()
        case .prompts:
            promptModel?.activate()
        case .chat:
            chatModel?.focus()
        case .inspirationLibrary:
            activateInspirationLibraryForCurrentRoute()
        case .globalSearch:
            if inspirationLibraryViewModel.screen == .detail,
               isGlobalSearchDetail {
                inspirationLibraryViewModel.activate()
            } else {
                globalSearchViewModel.activate()
            }
        }
    }

    private func openSelectedLibraryInspiration() {
        guard let identifier = inspirationLibraryViewModel.selectedID else { return }
        openInspirationFromLibrary(identifier: identifier)
    }

    private func activateInspirationLibraryForCurrentRoute() {
        if inspirationLibraryViewModel.screen == .detail,
           isGlobalSearchDetail {
            inspirationLibraryViewModel.activateListPreservingDetail()
        } else {
            inspirationLibraryViewModel.activate()
        }
    }

    private func openInspirationFromLibrary(identifier: Int64) {
        guard !detailTransitionInProgress else { return }
        if inspirationLibraryViewModel.screen == .detail {
            detailTransitionInProgress = true
            inspirationLibraryViewModel.returnToList { [weak self] succeeded in
                guard let self else { return }
                detailTransitionInProgress = false
                guard succeeded else { return }
                panelState.finishInspirationDetail()
                openInspirationFromLibrary(identifier: identifier)
            }
            return
        }
        panelState.beginInspirationDetail(from: .inspirationLibrary)
        if !inspirationLibraryViewModel.open(identifier: identifier) {
            panelState.finishInspirationDetail()
        }
    }

    private func openInspirationFromSearch(identifier: Int64) {
        guard panelState.selectedTab == .globalSearch,
              !detailTransitionInProgress else {
            return
        }
        if inspirationLibraryViewModel.screen == .detail {
            detailTransitionInProgress = true
            inspirationLibraryViewModel.returnToList { [weak self] succeeded in
                guard let self else { return }
                detailTransitionInProgress = false
                guard succeeded else { return }
                panelState.finishInspirationDetail()
                openInspirationFromSearch(identifier: identifier)
            }
            return
        }
        guard panelState.inspirationDetailOrigin == nil else { return }
        let resultID = SearchResultID(
            source: .inspiration,
            recordID: identifier
        )
        panelState.beginInspirationDetail(
            from: .globalSearch(
                resultID: resultID,
                queryRevision: globalSearchViewModel.queryRevision
            )
        )
        if !inspirationLibraryViewModel.openFromSearch(identifier: identifier) {
            panelState.finishInspirationDetail()
        }
    }

    private func returnFromInspirationDetail() {
        guard let origin = panelState.inspirationDetailOrigin,
              isInspirationDetailVisible,
              !detailTransitionInProgress else {
            return
        }
        detailTransitionInProgress = true
        inspirationLibraryViewModel.returnToList { [weak self] succeeded in
            guard let self else { return }
            detailTransitionInProgress = false
            guard succeeded else { return }
            panelState.finishInspirationDetail()
            switch origin {
            case .inspirationLibrary:
                inspirationLibraryViewModel.requestListFocus()
            case let .globalSearch(resultID, _):
                globalSearchViewModel.refresh(preferredID: resultID)
                globalSearchViewModel.requestInputFocus()
            }
        }
    }

    private func handleInspirationDetailLoadFailure(
        identifier: Int64,
        message: String
    ) {
        guard let origin = panelState.inspirationDetailOrigin else { return }
        panelState.finishInspirationDetail()
        detailTransitionInProgress = false
        switch origin {
        case .inspirationLibrary:
            inspirationLibraryViewModel.requestListFocus()
        case let .globalSearch(resultID, _):
            guard resultID.recordID == identifier else { return }
            globalSearchViewModel.reportInspirationOpenFailure(message: message)
            globalSearchViewModel.requestInputFocus()
        }
    }

    private var isGlobalSearchDetail: Bool {
        if case .globalSearch = panelState.inspirationDetailOrigin {
            return true
        }
        return false
    }

    private var isInspirationDetailVisible: Bool {
        guard !panelState.isSettingsOpen, inspirationLibraryViewModel.screen == .detail else { return false }
        switch panelState.inspirationDetailOrigin {
        case .inspirationLibrary:
            return panelState.selectedTab == .inspirationLibrary
        case .globalSearch:
            return panelState.selectedTab == .globalSearch
        case .none:
            return false
        }
    }

    private func resizePanel(expanded: Bool, animated: Bool) {
        guard let metrics = currentMetrics else { return }
        let frame = PanelGeometry.panelFrame(for: metrics, expanded: expanded)
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil

        guard animated, panel.isVisible, !panelState.reducesMotion else {
            panel.setFrame(frame, display: true)
            return
        }

        animatePanel(to: frame, duration: 0.36, curve: (0.22, 1, 0.36, 1))
    }

    /// Interruptible frame interpolation. NSWindow.animator can finish an obsolete frame
    /// after a hide/show; this single owner always starts from the current visual frame.
    private func animatePanel(to target: NSRect, duration: Double,
                              curve: (Double, Double, Double, Double), fadeIn: Bool = false) {
        frameAnimationTimer?.invalidate()
        let initial = panel.frame
        let initialAlpha = panel.alphaValue
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
                let eased = Self.cubicProgress(progress, curve: curve)
                func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
                self.panel.setFrame(NSRect(x: mix(initial.minX, target.minX), y: mix(initial.minY, target.minY),
                                      width: mix(initial.width, target.width), height: mix(initial.height, target.height)), display: true)
                if fadeIn { self.panel.alphaValue = min(1, mix(initialAlpha, 1)) }
                if progress >= 1 {
                    timer.invalidate()
                    self.frameAnimationTimer = nil
                    self.panel.setFrame(target, display: true)
                    self.panel.alphaValue = 1
                }
            }
        }
        frameAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func cubicProgress(_ progress: Double, curve: (Double, Double, Double, Double)) -> Double {
        if progress >= 1 { return 1 }
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let middle = (low + high) / 2
            if cubic(middle, curve.0, curve.2) < progress { low = middle } else { high = middle }
        }
        return cubic((low + high) / 2, curve.1, curve.3)
    }

    func openSettings() {
        guard chatModel?.canLeaveChat() != false else { return }
        guard chatModel?.confirmingDelete != true else { return }
        chatModel?.cancelAuthorization()
        guard promptModel?.flushEdit() != false else { return }
        promptModel?.panelDismissed()
        guard !panelState.isSettingsOpen, !detailTransitionInProgress else { return }
        if isInspirationDetailVisible {
            detailTransitionInProgress = true
            inspirationLibraryViewModel.flushBeforeTabChange { [weak self] succeeded in
                guard let self else { return }
                detailTransitionInProgress = false
                guard succeeded, panel.isVisible else { return }
                panel.makeFirstResponder(nil)
                panelState.openSettings()
            }
        } else {
            panel.makeFirstResponder(nil)
            panelState.openSettings()
        }
    }

    private func toggleSettings() {
        if panelState.isSettingsOpen { closeSettings() } else { openSettings() }
    }

    private func closeSettings() {
        guard settingsModel?.allowLeavingPrompt() != false else { return }
        guard settingsModel?.maintaining != true else { return }
        panelState.closeSettings()
        if isInspirationDetailVisible { inspirationLibraryViewModel.activate() }
        else { completeTabSelection(panelState.selectedTab) }
    }

    /// Only a noninteractive visual lingers; the real panel is hidden immediately.
    /// This preserves hot-zone toggling, external focus and all existing dismissal contracts.
    private func animateDismissalVisual() {
        autoreleasepool { makeDismissalVisual() }
    }

    private func makeDismissalVisual() {
        closingVisual?.close()
        closingVisual = nil
        guard panel.isVisible, !panelState.reducesMotion,
              let view = panel.contentView,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(view.bounds.width)), pixelsHigh: Int(ceil(view.bounds.height)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return }
        // The 240ms fading copy needs only 1 pixel per point, not a full Retina cache.
        // Keep the real interactive window at native resolution.
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let ghost = NSWindow(contentRect: panel.frame, styleMask: .borderless, backing: .buffered, defer: false)
        ghost.isReleasedWhenClosed = false
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.ignoresMouseEvents = true
        ghost.level = panel.level
        ghost.collectionBehavior = panel.collectionBehavior
        let imageView = NSImageView(frame: view.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        ghost.contentView = imageView
        ghost.orderFrontRegardless()
        closingVisual = ghost
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
            ghost.animator().alphaValue = 0
            ghost.animator().setFrame(ghost.frame.offsetBy(dx: 0, dy: 6), display: true)
        } completionHandler: { [weak self, weak ghost] in
            ghost?.close()
            (ghost?.contentView as? NSImageView)?.image = nil
            if self?.closingVisual === ghost { self?.closingVisual = nil }
        }
    }
}

private final class JotBloomPanel: NSPanel {
    var onSettingsKey: ((NSEvent) -> Bool)?
    var onKeyboardInteraction: (() -> Void)?
    var onPointerInteraction: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSaveInspiration: (() -> Void)?
    var onDiscuss: (() -> Void)?
    var isChatActive: (() -> Bool)?
    var onNewChat: (() -> Void)?
    var onSaveChatSummary: (() -> Void)?
    var onSaveInspirationDetail: (() -> Void)?
    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?
    var isInspirationActive: (() -> Bool)?
    var isClipboardActive: (() -> Bool)?
    var isInspirationLibraryListActive: (() -> Bool)?
    var isInspirationLibraryDetailActive: (() -> Bool)?
    var isGlobalSearchActive: (() -> Bool)?
    var onSelectInspiration: (() -> Void)?
    var onSelectClipboard: (() -> Void)?
    var onSelectInspirationLibrary: (() -> Void)?
    var onSelectGlobalSearch: (() -> Void)?
    var onMoveClipboardSelection: ((Int) -> Void)?
    var onActivateClipboardSelection: (() -> Void)?
    var onCopyClipboardSelection: (() -> Void)?
    var onDeleteClipboardSelection: (() -> Void)?
    var onUndoClipboardDeletion: (() -> Void)?
    var onMoveInspirationSelection: ((Int) -> Void)?
    var onOpenInspirationSelection: (() -> Void)?
    var onDeleteInspirationSelection: (() -> Void)?
    var onUndoInspirationDeletion: (() -> Void)?
    var onMoveSearchSelection: ((Int) -> Void)?
    var onActivateSearchSelection: (() -> Void)?
    var onCopySearchSelection: (() -> Bool)?
    var onQuit: (() -> Void)?
    var onSettings: (() -> Void)?
    var onSelectSlot: ((Int) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

#if DEBUG
    var debugHasMarkedText: Bool { hasMarkedText }

    func debugClearMarkedText() {
        (firstResponder as? NSTextInputClient)?.unmarkText()
    }
#endif

    override func sendEvent(_ event: NSEvent) {
        if (event.type == .keyDown || event.type == .flagsChanged), onSettingsKey?(event) == true { return }
        switch event.type {
        case .keyDown: onKeyboardInteraction?()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            onPointerInteraction?()
        default: break
        }
        let relevantModifiers = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        if event.type == .keyDown,
           relevantModifiers.isEmpty,
           !hasMarkedText {
            switch Int(event.keyCode) {
            case kVK_UpArrow:
                if isGlobalSearchActive?() == true {
                    onMoveSearchSelection?(-1)
                    return
                }
                if isClipboardActive?() == true {
                    onMoveClipboardSelection?(-1)
                    return
                }
                if isInspirationLibraryListActive?() == true {
                    onMoveInspirationSelection?(-1)
                    return
                }
            case kVK_DownArrow:
                if isGlobalSearchActive?() == true {
                    onMoveSearchSelection?(1)
                    return
                }
                if isClipboardActive?() == true {
                    onMoveClipboardSelection?(1)
                    return
                }
                if isInspirationLibraryListActive?() == true {
                    onMoveInspirationSelection?(1)
                    return
                }
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if isGlobalSearchActive?() == true {
                    onActivateSearchSelection?()
                    return
                }
                if isClipboardActive?() == true {
                    // Give focused native/SwiftUI row controls their own activation.
                    // A list responder means Enter still copies the selected record.
                    guard firstResponder is ListKeyboardResponder else { super.sendEvent(event); return }
                    onActivateClipboardSelection?()
                    return
                }
                if isInspirationLibraryListActive?() == true {
                    onOpenInspirationSelection?()
                    return
                }
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, onSettingsKey?(event) == true { return true }
        if event.type == .keyDown { onKeyboardInteraction?() }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            if hasMarkedText {
                return super.performKeyEquivalent(with: event)
            }
            onEscape?()
            return true
        }

        let relevantModifiers = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        if event.type == .keyDown, relevantModifiers == [.command, .shift],
           (event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)),
           isInspirationActive?() == true, !hasMarkedText {
            onDiscuss?(); return true
        }
        guard event.type == .keyDown, relevantModifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }

        switch Int(event.keyCode) {
        case kVK_ANSI_N where isChatActive?() == true:
            onNewChat?(); return true
        case kVK_ANSI_S where isChatActive?() == true:
            onSaveChatSummary?(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if isInspirationActive?() == true {
                if hasMarkedText { return super.performKeyEquivalent(with: event) }
                onSaveInspiration?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        case kVK_ANSI_S where isInspirationLibraryDetailActive?() == true:
            onSaveInspirationDetail?()
            return true
        case kVK_DownArrow:
            onExpand?()
            return true
        case kVK_UpArrow:
            onCollapse?()
            return true
        case kVK_ANSI_1:
            return onSelectSlot?(0) ?? false
        case kVK_ANSI_2:
            return onSelectSlot?(1) ?? false
        case kVK_ANSI_3:
            return onSelectSlot?(2) ?? false
        case kVK_ANSI_4:
            return onSelectSlot?(3) ?? false
        case kVK_ANSI_5:
            return onSelectSlot?(4) ?? false
        case kVK_ANSI_6:
            return onSelectSlot?(5) ?? false
        case kVK_ANSI_Comma:
            onSettings?()
            return true
        case kVK_ANSI_F:
            onSelectGlobalSearch?()
            return true
        case kVK_ANSI_C where isClipboardActive?() == true:
            onCopyClipboardSelection?()
            return true
        case kVK_ANSI_C where isGlobalSearchActive?() == true:
            if hasSelectedText {
                return super.performKeyEquivalent(with: event)
            }
            if onCopySearchSelection?() == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        case kVK_Delete, kVK_ForwardDelete:
            if isClipboardActive?() == true {
                onDeleteClipboardSelection?()
                return true
            }
            if isInspirationLibraryListActive?() == true {
                onDeleteInspirationSelection?()
                return true
            }
        case kVK_ANSI_Z where isClipboardActive?() == true:
            onUndoClipboardDeletion?()
            return true
        case kVK_ANSI_Z where isInspirationLibraryListActive?() == true:
            onUndoInspirationDeletion?()
            return true
        case kVK_ANSI_Q:
            onQuit?()
            return true
        default:
            break
        }

        return super.performKeyEquivalent(with: event)
    }

    private var hasMarkedText: Bool {
        guard let textInputClient = firstResponder as? NSTextInputClient else {
            return false
        }
        return textInputClient.hasMarkedText()
    }

    private var hasSelectedText: Bool {
        guard let textView = firstResponder as? NSTextView else { return false }
        return textView.selectedRange().length > 0
    }
}

private final class PanelMaterialView: NSView {
    private let outlineMask = CAShapeLayer()

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 5/255, green: 6/255, blue: 8/255, alpha: 1).cgColor
        // Explicit geometry also survives AppKit's cached rendering used for dismissal.
        // A cornerRadius + maskedCorners layer was rounded on all corners in that path.
        let radius: CGFloat = 20
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: bounds.height))
        path.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
        path.addLine(to: CGPoint(x: bounds.width, y: radius))
        path.addQuadCurve(to: CGPoint(x: bounds.width - radius, y: 0), control: CGPoint(x: bounds.width, y: 0))
        path.addLine(to: CGPoint(x: radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: radius), control: .zero)
        path.closeSubpath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineMask.frame = bounds
        outlineMask.path = path
        layer?.cornerRadius = 0
        layer?.mask = outlineMask
        CATransaction.commit()
        layer?.masksToBounds = true
    }
}
