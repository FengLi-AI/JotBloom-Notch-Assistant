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
    private let fileShelfModel: FileShelfViewModel?
    private let fileShelfDrag: FileShelfDragController?
    private var fileDragActive = false
    private var shelfPreviousPreview = false
    private var shelfPreviousExpansion = false
    var onChatCopy: (String) -> Bool = { _ in false }
    private var systemInteractionDepth = 0
    private var focusEventGeneration: UInt64 = 0
    private var restoringSystemFocus = false
    private var suspendedForDirectorySelection = false
    private var restoreAfterDirectorySelection = false
    private var appearanceReveal: BloomThemeRevealView?
    private var closingVisual: NSWindow?
    private var frameAnimationTimer: Timer?
    private var currentMetrics: ScreenMetrics?
    private var expansionChangesAnimated = true
    private var expansionUpdateGeneration: UInt64 = 0
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
        chatModel: ChatViewModel? = nil,
        fileShelfModel: FileShelfViewModel? = nil,
        fileShelfDrag: FileShelfDragController? = nil
    ) {
        self.inspirationViewModel = inspirationViewModel
        self.clipboardViewModel = clipboardViewModel
        self.inspirationLibraryViewModel = inspirationLibraryViewModel
        self.globalSearchViewModel = globalSearchViewModel
        self.dataDirectory = dataDirectory
        self.settingsModel = settingsModel
        self.promptModel = promptModel
        self.chatModel = chatModel
        self.fileShelfModel = fileShelfModel
        self.fileShelfDrag = fileShelfDrag
        super.init()
        fileShelfDrag?.panelFrame = { [weak self] in self?.panel.frame ?? .zero }
        fileShelfDrag?.onActivity = { [weak self] active in
            self?.focusEventGeneration &+= 1
            self?.fileDragActive = active
        }
        panelState.onChangeAppearance = { [weak self] appearance, rect in self?.changeAppearance(appearance, controlRect: rect) }
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
                // @Published emits before assignment. Resizing synchronously can
                // lay out the embedded native grid using the previous SwiftUI route.
                guard let self else { return }
                expansionUpdateGeneration &+= 1
                // present/dismiss own their final frame. A deferred reset must not
                // cancel the new presentation's fade and leave its alpha at zero.
                guard expansionChangesAnimated else { return }
                let generation = expansionUpdateGeneration
                let wasExpanded = panelState.isExpanded
                // Stage the visual starting point before @Published assigns the
                // new route. Deferring this lets SwiftUI render the endpoint for
                // one frame, then jump back when the window animation begins.
                let prepared = prepareLibraryResize(expanded: isExpanded, wasExpanded: wasExpanded)
                DispatchQueue.main.async { [weak self] in
                    guard let self, expansionUpdateGeneration == generation,
                          panelState.isPresented, !suspendedForDirectorySelection,
                          panelState.isExpanded == isExpanded else { return }
                    resizePanel(expanded: isExpanded, animated: true, wasExpanded: wasExpanded, transitionPrepared: prepared)
                }
            }
            .store(in: &cancellables)

        panelState.$preferences.dropFirst().sink { [weak self] preferences in
            guard let self else { return }
            panel.appearance = NSAppearance(named: preferences.appearance == .dark ? .darkAqua : .aqua)
            guard preferences.reduceMotion else { return }
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
    /// Sample intermediate layout, not only the final 300/700-point window frame.
    func debugPolishLayoutProbe(output: URL) async throws -> [(String, Bool)] {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_POLISH_SMOKE"] == "1" else { return [] }
        var checks: [(String, Bool)] = []
        var samples: [[String: Double]] = []
        func settle() async throws { try await Task.sleep(nanoseconds: 500_000_000) }
        func trace(_ name: String, expanding: Bool, action: () -> Void) async throws {
            let top = panel.frame.maxY
            var previous = panel.frame.height
            var monotonic = true, topFixed = true, chromeFixed = true, headerFixed = true, shadowFollows = true
            var measuredHeaderFrames = 0
            let expectedHeaderY = panelState.notchHeight + (name.contains("settings") ? 16 : BloomListLayout.verticalInset)
            action()
            for index in 0..<26 {
                try await Task.sleep(nanoseconds: 16_000_000)
                panel.contentView?.layoutSubtreeIfNeeded()
                let height = panel.frame.height
                if index == 0 { print("EDGE_SHADOW_FRAME", name, panel.frame, panel.childWindows?.first?.frame as Any) }
                shadowFollows = shadowFollows && panel.childWindows?.first?.frame == panel.frame.insetBy(dx: -18, dy: -18)
                monotonic = monotonic && (expanding ? height >= previous - 0.5 : height <= previous + 0.5)
                topFixed = topFixed && abs(panel.frame.maxY - top) < 0.5
                let chromeY = BloomLayoutDiagnostics.frames["chrome"]?.minY ?? -999
                let headerY = BloomLayoutDiagnostics.frames[name.contains("settings") ? "settingsHeader" : "libraryViewport"]?.minY ?? -999
                chromeFixed = chromeFixed && abs(chromeY) < 0.5
                // A newly mounted SwiftUI header publishes its first measurement asynchronously.
                // Missing data is not a position; still require at least 25 of the 26 samples.
                if headerY != -999 {
                    measuredHeaderFrames += 1
                    headerFixed = headerFixed && abs(headerY - expectedHeaderY) < 0.5
                }
                samples.append(["height": height, "chromeY": chromeY, "headerY": headerY, "frame": Double(index)])
                if [0, 5, 12, 25].contains(index) {
                    try debugCapturePromptPanel(to: output.appendingPathComponent("polish-\(name)-\(index).png"))
                }
                previous = height
            }
            checks += [(name + "_height_monotonic", monotonic), (name + "_window_top_fixed", topFixed),
                       (name + "_chrome_fixed", chromeFixed), (name + "_title_fixed", headerFixed && measuredHeaderFrames >= 25), (name + "_shadow_follows", shadowFollows)]
        }
        requestSelectTab(.inspirationLibrary); panelState.collapse(); try await settle()
        try await trace("library-expand", expanding: true) { panelState.expand() }
        try await trace("library-collapse", expanding: false) { panelState.collapse() }
        for tab: PanelTab in [.clipboard, .prompts, .inspirationLibrary] {
            requestSelectTab(tab); panelState.collapse(); try await settle()
            try await trace("settings-from-" + tab.rawValue, expanding: true) { openSettings() }
            closeSettings(); try await settle()
        }
        requestSelectTab(.inspiration); panelState.collapse(); try await settle()
        inspirationViewModel.text = "想给每周的灵感留五分钟。先选出一条还想继续的，写下下一步。"
        try await settle()
        if let input = BloomLayoutDiagnostics.frames["inspirationInput"],
           let actions = BloomLayoutDiagnostics.frames["inspirationActions"],
           let header = BloomLayoutDiagnostics.frames["captureHeader"] {
            checks.append(("input_to_actions_12", abs(actions.minY - input.maxY - 12) < 0.5))
            checks.append(("actions_bottom_inset_16", abs(panel.frame.height - actions.maxY - 16) < 0.5))
            checks.append(("capture_header_top_inset_10", abs(header.minY - input.minY - 10) < 0.5))
        } else { checks.append(("input_metrics_available", false)) }
        try debugCapturePromptPanel(to: output.appendingPathComponent("polish-input-populated.png"))
        let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("polish-motion-samples.json"))
        return checks
    }

    func debugUI13Probe(output: URL) async throws -> [(String, Bool)] {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_UI13_SMOKE"] == "1" else { return [] }
        var checks: [(String, Bool)] = []
        func pause(_ ms: UInt64 = 520) async throws { try await Task.sleep(nanoseconds: ms * 1_000_000) }
        func blueCenter(_ name: String, region: CGRect, horizontal: Bool = false) throws -> Double {
            let url = output.appendingPathComponent(name + ".png")
            try debugCapturePromptPanel(to: url)
            let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
            let scale = Double(bitmap.pixelsWide) / panel.frame.width
            var total = 0.0, count = 0.0
            for y in stride(from: Int(region.minY * scale), to: Int(region.maxY * scale), by: 3) {
                for x in stride(from: Int(region.minX * scale), to: Int(region.maxX * scale), by: 3) {
                    guard x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                          let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.blueComponent > 0.38 && color.blueComponent > color.redComponent * 1.6 && color.blueComponent > color.greenComponent * 1.2 {
                        total += Double(horizontal ? x : y) / scale; count += 1
                    }
                }
            }
            return count > 0 ? total / count : -1000
        }
        requestSelectTab(.inspirationLibrary); panelState.expand(); inspirationLibraryViewModel.filter(nil); try await pause()
        let region = CGRect(x: 16, y: panelState.notchHeight + 12, width: 104, height: 186)
        let start = try blueCenter("ui13-category-start", region: region)
        inspirationLibraryViewModel.filter(.product); try await pause()
        let end = try blueCenter("ui13-category-end", region: region)
        checks.append(("ui13_category_reaches_product", abs(end - start - 108) < 4))
        inspirationLibraryViewModel.filter(.article); try await pause(100)
        inspirationLibraryViewModel.filter(.idea); try await pause()
        checks.append(("ui13_rapid_filter_keeps_latest_state", inspirationLibraryViewModel.filterCategory == .idea))
        try debugCapturePromptPanel(to: output.appendingPathComponent("ui13-category-interrupted-end.png"))
        requestSelectTab(.prompts); promptModel?.favoritesOnly = false; try await pause()
        let promptRegion = CGRect(x: 16, y: panelState.notchHeight + 36, width: 104, height: 76)
        let promptStart = try blueCenter("ui13-prompt-start", region: promptRegion)
        promptModel?.favoritesOnly = true; try await pause()
        let promptEnd = try blueCenter("ui13-prompt-end", region: promptRegion)
        checks.append(("ui13_prompt_sidebar_selects_favorites", abs(promptEnd - promptStart - 36) < 4))
        requestSelectTab(.globalSearch); globalSearchViewModel.selectScope(.all); try await pause()
        let searchRegion = CGRect(x: 16, y: 82, width: 408, height: 33)
        let searchStart = try blueCenter("ui13-search-start", region: searchRegion, horizontal: true)
        globalSearchViewModel.selectScope(.prompt); try await pause(140)
        let searchMiddle = try blueCenter("ui13-search-middle", region: searchRegion, horizontal: true)
        try await pause()
        let searchEnd = try blueCenter("ui13-search-end", region: searchRegion, horizontal: true)
        checks.append(("ui13_search_selection_slides", searchMiddle > searchStart + 3 && searchMiddle < searchEnd - 3 && searchEnd > searchStart + 100))
        openSettings(); panelState.settingsSection = "general"; try await pause()
        let settingsRegion = CGRect(x: 20, y: 100, width: 114, height: 322)
        let settingsStart = try blueCenter("ui13-settings-start", region: settingsRegion)
        panelState.settingsSection = "storage"; try await pause(140)
        let settingsMiddle = try blueCenter("ui13-settings-middle", region: settingsRegion)
        try await pause()
        let settingsEnd = try blueCenter("ui13-settings-end", region: settingsRegion)
        checks.append(("ui13_settings_selection_slides", settingsMiddle > settingsStart + 3 && settingsMiddle < settingsEnd - 3 && abs(settingsEnd - settingsStart - 138) < 4))
        panelState.settingsSection = "general"; try await pause()
        func indicators(_ view: NSView) -> [BloomScrollIndicator] {
            (view as? BloomScrollIndicator).map { [$0] } ?? view.subviews.flatMap(indicators)
        }
        if let content = panel.contentView, let indicator = indicators(content).max(by: {
            ($0.scroll?.documentView?.bounds.height ?? 0) < ($1.scroll?.documentView?.bounds.height ?? 0)
        }), let scroll = indicator.scroll {
            checks.append(("ui13_system_scrollbar_replaced", !scroll.hasVerticalScroller))
            scroll.contentView.scroll(to: .init(x: 0, y: 120)); scroll.reflectScrolledClipView(scroll.contentView)
            try await pause(60)
            checks.append(("ui13_scrollbar_slides_in", indicator.shown && indicator.debugSlide > 0 && indicator.debugSlide < 10))
            try await pause(300)
            checks.append(("ui13_scrollbar_thin_visible", indicator.shown && indicator.debugThumbRect.width == 3 && indicator.debugSlide == 0))
            try debugCapturePromptPanel(to: output.appendingPathComponent("ui13-scrollbar-visible.png"))
            let origin = scroll.contentView.bounds.minY
            let thumb = indicator.debugThumbRect
            let hitPoint = indicator.convert(.init(x: thumb.midX, y: thumb.midY), to: indicator.superview)
            checks.append(("ui13_scrollbar_hit_target", indicator.hitTest(hitPoint) === indicator))
            let point = indicator.convert(.init(x: thumb.midX, y: thumb.midY), to: nil)
            func mouse(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            indicator.mouseDown(with: mouse(.leftMouseDown, point: point))
            let destination = indicator.convert(.init(x: thumb.midX, y: thumb.midY + 35), to: nil)
            indicator.mouseDragged(with: mouse(.leftMouseDragged, point: destination))
            indicator.mouseUp(with: mouse(.leftMouseUp, point: destination))
            checks.append(("ui13_scrollbar_drag_moves_document", scroll.contentView.bounds.minY > origin + 20))
            try await pause(1300)
            checks.append(("ui13_scrollbar_lingers", indicator.shown))
            try await pause(800)
            checks.append(("ui13_scrollbar_slides_out", !indicator.shown && indicator.debugSlide > 0 && indicator.debugSlide < 10))
            try await pause(400)
            checks.append(("ui13_scrollbar_hidden_after_idle", !indicator.shown && indicator.debugSlide == 10))
            try debugCapturePromptPanel(to: output.appendingPathComponent("ui13-scrollbar-idle.png"))
            panelState.preferences.reduceMotion = true; try await pause(100)
            scroll.contentView.scroll(to: .init(x: 0, y: 80)); scroll.reflectScrolledClipView(scroll.contentView)
            try await pause(20)
            checks.append(("ui13_reduced_motion_scrollbar_immediate", indicator.shown && indicator.debugSlide == 0))
            panelState.preferences.reduceMotion = false
        } else { checks.append(("ui13_scrollbar_installed", false)) }
        panelState.settingsSection = "about"; try await pause()
        try debugCapturePromptPanel(to: output.appendingPathComponent("ui13-about.png"))
        closeSettings(); requestSelectTab(.inspiration); panelState.collapse(); try await pause()
        try debugCapturePromptPanel(to: output.appendingPathComponent("ui13-input.png"))
        let data = try JSONSerialization.data(withJSONObject: ["categoryStart": start, "categoryEnd": end, "promptStart": promptStart, "promptEnd": promptEnd], options: .prettyPrinted)
        try data.write(to: output.appendingPathComponent("ui13-selection-motion.json"))
        return checks
    }

    func debugUI12Probe(output: URL) async throws -> [(String, Bool)] {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_UI12_SMOKE"] == "1" else { return [] }
        var checks: [(String, Bool)] = []
        func settle() async throws { try await Task.sleep(nanoseconds: 480_000_000) }
        func matches(_ expanded: Bool) -> Bool {
            panelState.isExpanded == expanded && currentMetrics.map {
                panel.frame == PanelGeometry.panelFrame(for: $0, expanded: expanded)
            } == true
        }
        for normal: PanelTab in [.inspiration, .clipboard, .prompts, .inspirationLibrary] {
            for expanded in [false, true] {
                for first: PanelTab in [.chat, .globalSearch] {
                    requestSelectTab(normal); debugSetExpanded(expanded); try await settle()
                    requestSelectTab(first); try await settle()
                    let entered = matches(true)
                    requestSelectTab(first == .chat ? .globalSearch : .chat); try await settle()
                    let crossed = matches(true)
                    openSettings(); try await settle(); closeSettings(); try await settle()
                    requestSelectTab(normal); try await settle()
                    checks.append(("ui12_\(normal.rawValue)_\(expanded)_via_\(first.rawValue)", entered && crossed && matches(expanded)))
                }
            }
        }
        checks.append(("ui12_bundled_misans", BloomTypography.bundledFontsAvailable))
        checks.append(("ui12_labels_regular", BloomTypography.nsFont(12, role: .label).fontName == "MiSans-Regular"))
        checks.append(("ui12_body_normal", BloomTypography.nsFont(12).fontName == "MiSans-Normal"))
        requestSelectTab(.inspiration); panelState.collapse(); try await settle()
        inspirationViewModel.text = "给闪过的想法，一点空间。记录下来，然后继续手头的事。"
        try await settle()
        try debugCapturePromptPanel(to: output.appendingPathComponent("ui12-gradient-a.png"))
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try debugCapturePromptPanel(to: output.appendingPathComponent("ui12-gradient-b.png"))
        requestSelectTab(.inspirationLibrary); try await settle()
        try debugCapturePromptPanel(to: output.appendingPathComponent("ui12-library.png"))
        openSettings(); panelState.settingsSection = "about"; try await settle()
        try debugCapturePromptPanel(to: output.appendingPathComponent("ui12-about.png"))
        closeSettings()
        return checks
    }

    func debugThemeProbe(output: URL) async throws -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let original = panelState.preferences
        let dismissalWasEnabled = automaticDismissalEnabled
        automaticDismissalEnabled = false
        defer { panelState.preferences = original; automaticDismissalEnabled = dismissalWasEnabled }
        func settle() async throws { try await Task.sleep(nanoseconds: 600_000_000) }
        inspirationViewModel.text = "给闪过的想法，一点空间。\n记下来，然后继续手头的事。"
        chatModel?.draft = "把这周值得继续的灵感，留到周五再看看。"
        for appearance in PanelAppearance.allCases {
            panelState.preferences.appearance = appearance
            try await settle()
            let prefix = appearance.rawValue
            checks.append((prefix + "_native_appearance", panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == (appearance == .dark ? .darkAqua : .aqua)))
            for expanded in [false, true] {
                requestSelectTab(.inspiration); panelState.collapse(); try await settle()
                if expanded { panelState.expand(); try await settle() }
                for tab: PanelTab in [.inspiration, .clipboard, .prompts, .inspirationLibrary, .chat, .globalSearch] {
                    requestSelectTab(tab); try await settle()
                    let label = prefix + "-" + tab.rawValue + (expanded ? "-expanded" : "-default")
                    let url = output.appendingPathComponent(label + ".png")
                    try debugCapturePromptPanel(to: url)
                    let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
                    // Sample the unadorned page background, not just a resolved palette token.
                    let color = bitmap.colorAt(x: bitmap.pixelsWide - 10, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
                    checks.append((label + "_rendered_palette", appearance == .dark ? color.redComponent < 0.18 : color.redComponent > 0.80 && color.redComponent < 0.995))
                    let bottom = BloomLayoutDiagnostics.frames["panelFooterControls"]?.maxY ?? -999
                    let compactFooter = [.clipboard, .prompts, .inspirationLibrary].contains(tab)
                    let bottomInset: CGFloat = compactFooter ? BloomListLayout.verticalInset + 1 : 16
                    checks.append((label + "_bottom_inset", abs(panel.frame.height - bottom - bottomInset) < 0.5))
                    checks.append((label + "_expansion", panelState.isExpanded == (expanded || tab == .chat || tab == .globalSearch)))
                }
                requestSelectTab(.clipboard); try await settle()
                checks.append((prefix + "_returns_normal_size_" + String(expanded), panelState.isExpanded == expanded))
            }
            openSettings(); panelState.settingsSection = "general"; try await settle()
            try debugCapturePromptPanel(to: output.appendingPathComponent(prefix + "-settings.png"))
            let frame = panel.frame
            let draft = inspirationViewModel.text
            let chatDraft = chatModel?.draft
            panelState.preferences.appearance = appearance == .dark ? .light : .dark
            try await settle()
            checks.append((prefix + "_switch_preserves_settings_frame_and_drafts", panel.frame == frame && panelState.isSettingsOpen && panelState.settingsSection == "general" && inspirationViewModel.text == draft && chatModel?.draft == chatDraft))
            panelState.preferences.appearance = appearance
            for section in ["ai", "systemPrompt", "about"] {
                panelState.settingsSection = section; try await settle()
                try debugCapturePromptPanel(to: output.appendingPathComponent(prefix + "-settings-" + section + ".png"))
            }
            closeSettings(); try await settle()
        }
        print("THEME_OUTPUT", output.path)
        return checks
    }

    func debugThemePolish11(output: URL, show: () -> Void) async throws -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let previous = automaticDismissalEnabled; automaticDismissalEnabled = false
        defer { automaticDismissalEnabled = previous }
        func pause(_ ms: UInt64 = 500) async throws { try await Task.sleep(nanoseconds: ms * 1_000_000) }
        for appearance in PanelAppearance.allCases {
            panelState.preferences.appearance = appearance
            requestSelectTab(.inspiration); panelState.collapse(); try await pause()
            inspirationViewModel.text = "给闪过的想法，一点空间。"; try await pause()
            try debugCapturePromptPanel(to: output.appendingPathComponent(appearance.rawValue + "-buttons-active.png"))
            inspirationViewModel.text = ""; try await pause()
            try debugCapturePromptPanel(to: output.appendingPathComponent(appearance.rawValue + "-buttons-disabled.png"))
            for (tab, label): (PanelTab, String) in [(.clipboard, "clipboard"), (.prompts, "prompt"), (.inspirationLibrary, "library")] {
                requestSelectTab(tab); try await pause()
                let bottom = BloomLayoutDiagnostics.frames[label + "FooterText"]?.maxY ?? -999
                checks.append((appearance.rawValue + "_" + label + "_description_bottom_16", abs(panel.frame.height - bottom - 16) < 0.5))
                try debugCapturePromptPanel(to: output.appendingPathComponent(appearance.rawValue + "-" + label + ".png"))
            }
        }
        panelState.preferences.appearance = .light
        onRequestHide?(); try await pause(); show()
        var alphas: [CGFloat] = []
        for index in 0..<5 {
            try await pause(45)
            alphas.append(panel.alphaValue)
            checks.append(("light_show_appearance_" + String(index), panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua))
            try debugCapturePromptPanel(to: output.appendingPathComponent("light-show-" + String(index) + ".png"))
        }
        checks.append(("light_show_alpha_monotonic", zip(alphas, alphas.dropFirst()).allSatisfy { $0 <= $1 }))
        if let shadow = panel.childWindows?.first?.contentView,
           let bitmap = shadow.bitmapImageRepForCachingDisplay(in: shadow.bounds) {
            shadow.cacheDisplay(in: shadow.bounds, to: bitmap)
            checks.append(("shadow_panel_interior_transparent", (bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 1) < 0.01))
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("shadow-alpha.png"))
        } else { checks.append(("shadow_available", false)) }
        openSettings(); panelState.settingsSection = "general"; try await pause()
        for target in [PanelAppearance.dark, .light] {
            guard let frame = BloomLayoutDiagnostics.frames["appearanceControl"] else { checks.append(("control_measured", false)); continue }
            let rect = NSRect(x: frame.minX, y: panel.frame.height - frame.maxY, width: frame.width, height: frame.height)
            let draft = inspirationViewModel.text; let windowFrame = panel.frame
            changeAppearance(target, controlRect: rect)
            var radii: [CGFloat] = []
            for index in 0..<5 {
                try await pause(90)
                if let reveal = appearanceReveal { radii.append(reveal.debugRadius) }
                try debugCapturePromptPanel(to: output.appendingPathComponent("switch-" + target.rawValue + "-" + String(index) + ".png"))
            }
            checks.append((target.rawValue + "_reveal_expands", radii.count >= 3 && (radii.last ?? 0) > (radii.first ?? 0) + 50 && zip(radii, radii.dropFirst()).allSatisfy { $0 <= $1 }))
            try await pause(1200)
            checks.append((target.rawValue + "_reveal_cleanup", appearanceReveal == nil))
            checks.append((target.rawValue + "_reveal_preserves_frame_draft", panel.frame == windowFrame && inspirationViewModel.text == draft && panelState.preferences.appearance == target))
            try debugCapturePromptPanel(to: output.appendingPathComponent(target.rawValue + "-settings-end.png"))
        }
        panelState.preferences.reduceMotion = true
        if let frame = BloomLayoutDiagnostics.frames["appearanceControl"] {
            changeAppearance(.dark, controlRect: NSRect(x: frame.minX, y: panel.frame.height - frame.maxY, width: frame.width, height: frame.height))
            checks.append(("reduced_motion_switch_immediate", appearanceReveal == nil && panelState.preferences.appearance == .dark))
        }
        print("POLISH11_OUTPUT", output.path)
        return checks
    }

    func debugCircularThemeUpdate(output: URL) async throws -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let previous = automaticDismissalEnabled; automaticDismissalEnabled = false
        defer { automaticDismissalEnabled = previous }
        func pause(_ ms: UInt64) async throws { try await Task.sleep(nanoseconds: ms * 1_000_000) }
        openSettings(); panelState.settingsSection = "general"
        panelState.preferences.appearance = .light; try await pause(500)
        for target in [PanelAppearance.dark, .light] {
            guard let frame = BloomLayoutDiagnostics.frames["appearanceControl"] else { checks.append(("control_measured", false)); continue }
            let rect = NSRect(x: frame.minX, y: panel.frame.height - frame.maxY, width: frame.width, height: frame.height)
            let originalFrame = panel.frame
            changeAppearance(target, controlRect: rect)
            try await pause(50)
            checks.append((target.rawValue + "_control_opening_rounded", appearanceReveal?.debugRoundedControlOpening == true))
            var radii: [CGFloat] = []
            for _ in 0..<5 { try await pause(100); if let reveal = appearanceReveal { radii.append(reveal.debugRadius) } }
            checks.append((target.rawValue + "_circle_expands", radii.count == 5 && (radii.last ?? 0) > (radii.first ?? 0) + 40 && zip(radii, radii.dropFirst()).allSatisfy { $0 <= $1 }))
            try await pause(650)
            checks.append((target.rawValue + "_continues_past_old_duration", appearanceReveal != nil))
            try await pause(450)
            checks.append((target.rawValue + "_completed_and_cleaned", appearanceReveal == nil && panelState.preferences.appearance == target && panel.frame == originalFrame))
            try debugCapturePromptPanel(to: output.appendingPathComponent(target.rawValue + "-end.png"))
        }
        print("CIRCULAR_UPDATE_OUTPUT", output.path)
        return checks
    }

    /// Check opacity as well as window ordering: an ordered, fully transparent panel
    /// used to pass lifecycle checks while the companion correctly stayed hidden.
    func debugPresentationProbe(toggle: () -> Void) async throws -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let preferences = panelState.preferences
        defer { panelState.preferences = preferences }
        func settle() async throws { try await Task.sleep(nanoseconds: 600_000_000) }
        func visible() -> Bool {
            panel.isVisible && panelState.isPresented && panel.alphaValue == 1 &&
                panel.childWindows?.first?.alphaValue == 1 && frameAnimationTimer == nil &&
                currentMetrics.map { panel.frame == PanelGeometry.panelFrame(for: $0, expanded: panelState.isExpanded) } == true
        }
        try await settle()
        checks.append(("startup_panel_opaque", visible()))
        toggle(); try await settle()
        for slot: PanelSlot in [.inspiration, .clipboard, .prompts, .inspirationLibrary, .fileShelf, .chat, .globalSearch] {
            panelState.preferences.defaultSlot = slot
            toggle(); try await settle()
            checks.append(("notch_open_" + slot.rawValue, visible() && panelState.selectedTab.rawValue == slot.rawValue))
            toggle(); try await settle()
            checks.append(("notch_close_" + slot.rawValue, !panel.isVisible && !panelState.isPresented && closingVisual == nil))
        }
        panelState.preferences.defaultSlot = .clipboard
        toggle()
        panelState.expand(); panelState.collapse()
        toggle(); toggle()
        try await settle()
        checks.append(("queued_resize_then_reopen_opaque", visible() && !panelState.isExpanded))
        toggle(); try await settle()
        toggle(); beginFileShelfPreview()
        try await settle()
        checks.append(("shelf_preview_during_fade_opaque", visible() && panelState.isExpanded && panelState.fileShelfPreview))
        toggle(); try await settle()
        toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        let openingAlpha = panel.alphaValue
        toggle()
        checks.append(("early_close_preserves_opacity", closingVisual.map { abs($0.alphaValue - openingAlpha) < 0.01 } ?? (openingAlpha == 0)))
        try await settle()
        checks.append(("early_close_cleans_up", !panel.isVisible && closingVisual == nil))
        toggle(); beginFileShelfPreview()
        try await Task.sleep(nanoseconds: 100_000_000)
        checks.append(("shelf_resize_continues_fade", panel.alphaValue > 0))
        try await settle()
        toggle(); try await settle()
        panelState.preferences.reduceMotion = true
        toggle(); try await settle()
        checks.append(("reduced_motion_open_opaque", visible()))
        toggle(); try await settle()
        checks.append(("reduced_motion_close_hidden", !panel.isVisible && closingVisual == nil))
        return checks
    }

    func debugReviewLifecycleProbe(show: () -> Void, toggle: () -> Void) async throws -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        func settle() async throws { try await Task.sleep(nanoseconds: 550_000_000) }
        try await settle()
        if ProcessInfo.processInfo.environment["JOTBLOOM_THEME_CIRCULAR_UPDATE"] == "1", let dataDirectory {
            return try await debugCircularThemeUpdate(output: dataDirectory)
        }
        if ProcessInfo.processInfo.environment["JOTBLOOM_THEME_POLISH11"] == "1", let dataDirectory {
            return try await debugThemePolish11(output: dataDirectory, show: show)
        }
        if ProcessInfo.processInfo.environment["JOTBLOOM_THEME_SMOKE"] == "1", let dataDirectory {
            checks += try await debugThemeProbe(output: dataDirectory)
        }
        if ProcessInfo.processInfo.environment["JOTBLOOM_THEME_MOTION_SMOKE"] == "1", let dataDirectory {
            let previousAppearance = panelState.preferences.appearance
            automaticDismissalEnabled = false
            for appearance in PanelAppearance.allCases {
                panelState.preferences.appearance = appearance
                let folder = dataDirectory.appendingPathComponent(appearance.rawValue)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                checks += try await debugUI13Probe(output: folder).map { (appearance.rawValue + "_" + $0.0, $0.1) }
            }
            panelState.preferences.appearance = previousAppearance
            automaticDismissalEnabled = true
            print("THEME_MOTION_OUTPUT", dataDirectory.path)
        }
        checks.append(("review_automatic_dismissal_enabled", automaticDismissalEnabled))
        checks.append(("review_shadow_noninteractive", panel.childWindows?.count == 1 && panel.childWindows?.first?.ignoresMouseEvents == true && panel.childWindows?.first?.isKeyWindow == false))
        if ProcessInfo.processInfo.environment["JOTBLOOM_EDGE_PROBE"] == "1", let dataDirectory {
            if let frameView = panel.contentView?.superview {
                if let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: dataDirectory.appendingPathComponent("window-frame.png"))
                }
            }
            print("EDGE_OUTPUT", dataDirectory.path)
            checks += try await debugPolishLayoutProbe(output: dataDirectory)
        }
        if let dataDirectory {
            openSettings(); panelState.settingsSection = "about"; try await settle()
            try debugCapturePromptPanel(to: dataDirectory.appendingPathComponent("ui12-about.png"))
            closeSettings(); try await settle()
        }
        _ = debugPerformKeyEquivalent(keyCode: UInt16(kVK_Escape)); try await settle()
        checks.append(("review_escape_hides", !panel.isVisible))
        checks.append(("review_shadow_hides_with_panel", panel.childWindows?.allSatisfy { !$0.isVisible } == true))
        show(); try await settle()
        checks.append(("review_reopens", panel.isVisible))
        checks.append(("review_shadow_reattaches_on_reopen", panel.childWindows?.first?.isVisible == true && panel.childWindows?.first?.frame == panel.frame.insetBy(dx: -18, dy: -18)))
        toggle(); try await settle()
        checks.append(("review_toggle_hides", !panel.isVisible))
        show(); try await settle()
        let other = NSWindow(contentRect: .init(x: 100, y: 100, width: 100, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil); try await settle()
        checks.append(("review_external_focus_hides", !panel.isVisible))
        other.close()
        show(); try await settle()
        let url = URL(string: "https://fengli-ai.github.io/JotBloom-Notch-Assistant/")!
        let declined = BloomExternalLinks.action(using: .init { _ in .discarded }, onOpened: { self.onRequestHide?() })
        declined(url); try await settle()
        checks.append(("review_declined_url_keeps_panel", panel.isVisible))
        let accepted = BloomExternalLinks.action(using: .init { _ in .handled }, onOpened: { self.onRequestHide?() })
        accepted(url); try await settle()
        checks.append(("review_accepted_url_hides_panel", !panel.isVisible && !panelState.isPresented))
        return checks
    }
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
    /// Exercises real views and delegate handoffs with isolated test files only.
    func debugFileShelfProbe(output: URL, show: () -> Void) async throws -> Bool {
        guard ProcessInfo.processInfo.environment["JOTBLOOM_FILE_SHELF_REVIEW"] != nil,
              let model = fileShelfModel, let drag = fileShelfDrag, let first = model.items.first else { return false }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        automaticDismissalEnabled = false
        panelState.preferences.reduceMotion = true
        var checks: [(String, Bool)] = []
        func settle() async { try? await Task.sleep(nanoseconds: 280_000_000) }
        func findGrid(_ view: NSView?) -> ShelfCollectionView? {
            guard let view else { return nil }
            if let grid = view as? ShelfCollectionView { return grid }
            return view.subviews.lazy.compactMap { findGrid($0) }.first
        }
        for appearance: PanelAppearance in [.dark, .light] {
            panelState.preferences.appearance = appearance
            for scale in [0.85, 1.0, 1.2] {
                for expanded in [false, true] {
                    debugSetExpanded(expanded)
                    await settle()
                    panel.setFrame(NSRect(x: 400, y: 60, width: 640 * scale, height: (expanded ? 700 : 300) * scale), display: true)
                    await settle()
                    let name = "\(appearance.rawValue)-\(Int(scale * 100))-\(expanded ? "expanded" : "compact")"
                    try debugCapturePromptPanel(to: output.appendingPathComponent(name + ".png"))
                    if let grid = findGrid(panel.contentView), let layout = grid.collectionViewLayout {
                        let visible = layout.layoutAttributesForElements(in: grid.visibleRect).filter { grid.visibleRect.insetBy(dx: -1, dy: -1).contains($0.frame) }
                        let valid = grid.numberOfItems(inSection: 0) == model.items.count && visible.count >= min(6, model.items.count)
                            && visible.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= grid.bounds.width + 1 }
                        checks.append((name, valid))
                    } else { checks.append((name, false)) }
                }
            }
        }
        panelState.preferences.appearance = .dark
        _ = present(); debugShowFileShelf(); await settle()
        guard let grid = findGrid(panel.contentView), let owner = grid.owner else { return false }
        if let layout = grid.collectionViewLayout {
            let gap = layout.layoutAttributesForDropTarget(at: NSPoint(x: 10, y: layout.collectionViewContentSize.height + 40))
            checks.append(("native_empty_space_is_append_target", gap?.representedElementCategory == .interItemGap && gap?.indexPath?.item == model.items.count))
        }
        if let layout = grid.collectionViewLayout as? ShelfFlowLayout {
            let total = model.items.count
            func frames() -> [NSRect] { (0..<total).compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame } }
            let originalFrames = frames()
            layout.reducesMotion = true
            layout.setDrag(excluding: [1], insertion: 1)
            checks.append(("lift_keeps_neighbors_in_place", frames().enumerated().allSatisfy { $0.offset == 1 || $0.element == originalFrames[$0.offset] }))
            checks.append(("lift_hides_only_dragged_item", (0..<total).filter { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.alpha == 0 } == [1]))
            layout.setDrag(excluding: [1], insertion: total - 1)
            let movedFrames = frames()
            checks.append(("single_gap_no_source_hole", (1..<(total - 1)).allSatisfy { movedFrames[$0 + 1] == originalFrames[$0] }))
            layout.setDrag(excluding: [], insertion: nil)
            checks.append(("outside_restores_full_order_no_gap", frames() == originalFrames && layout.insertion == nil))
            layout.setDrag(excluding: [0, 2], insertion: 2)
            checks.append(("batch_drag_uses_one_gap", layout.excluded.count == 2 && layout.insertion == 2 && layout.originalIndex(forInsertion: 2) == 4))
            layout.setDrag(excluding: [], insertion: nil)
            layout.reducesMotion = false
            layout.setDrag(excluding: [1], insertion: total - 1)
            try await Task.sleep(nanoseconds: 80_000_000)
            let intermediate = frames()
            checks.append(("reorder_has_intermediate_positions", intermediate[2] != originalFrames[2] && intermediate[2] != movedFrames[2]))
            await settle()
            checks.append(("reorder_settles_at_target", frames()[2] == movedFrames[2]))
            try debugCapturePromptPanel(to: output.appendingPathComponent("single-gap-sort.png"))
            layout.setDrag(excluding: [], insertion: nil, animated: false)
        }
        let ids = Set(model.items.prefix(2).map(\.id))
        model.selection = ids
        let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        let paths = Set(model.items.indices.prefix(2).map { IndexPath(item: $0, section: 0) })
        checks.append(("native_drag_selection_available", owner.collectionView(grid, canDragItemsAt: paths, with: event)))
        let pasteboard = NSPasteboard.withUniqueName()
        let writers = paths.sorted().compactMap { owner.collectionView(grid, pasteboardWriterForItemAt: $0) }
        pasteboard.writeObjects(writers)
        checks.append(("native_pasteboard_original_urls", Set(FileShelfDragController.urls(pasteboard)) == Set(model.items.prefix(2).map(\.url))))
        pasteboard.releaseGlobally()
        let previous = model.items.map(\.id)
        drag.startInternal(ids)
        let internalInfo = FileShelfReviewDrag(urls: model.items.prefix(2).map(\.url), source: grid)
        let accepted = owner.collectionView(grid, acceptDrop: internalInfo, indexPath: IndexPath(item: model.items.count, section: 0), dropOperation: .before)
        drag.endInternal(.move)
        await settle()
        checks.append(("native_group_reorder", accepted && model.items.map(\.id) == Array(previous.dropFirst(2)) + Array(previous.prefix(2)) && panel.isVisible))
        let reordered = model.items.map(\.id)
        drag.startInternal(ids); drag.endInternal([])
        checks.append(("rejected_drag_keeps_order_and_panel", model.items.map(\.id) == reordered && panel.isVisible))
        model.kind = .image; model.date = .yesterday
        requestSelectTab(.inspiration); panelState.collapse()
        inspirationViewModel.text = "文件中转站回归测试草稿"
        let external = FileShelfReviewDrag(urls: [first.url])
        checks.append(("notch_hover_keeps_page_size_filters", drag.enter(external, notchFrame: NSRect(x: 500, y: 900, width: 179, height: 32)) && !panelState.fileShelfPreview && !panelState.isExpanded && model.kind == .image && model.date == .yesterday && drag.notchFeedback.phase == .hover))
        drag.cancel()
        checks.append(("cancel_restores_page_filters_and_draft", !panelState.fileShelfPreview && !panelState.isExpanded && panelState.selectedTab == .inspiration && model.kind == .image && model.date == .yesterday && inspirationViewModel.text == "文件中转站回归测试草稿"))
        let receiver = NotchDropView(frame: NSRect(x: 0, y: 0, width: 175, height: 32)); receiver.fileShelf = drag
        let cancelledDrag = FileShelfReviewDrag(urls: [first.url])
        _ = receiver.draggingEntered(cancelledDrag); receiver.draggingEnded(cancelledDrag)
        checks.append(("native_drag_end_restores_cancelled_preview", !drag.active && !panelState.fileShelfPreview && model.kind == .image && model.date == .yesterday))
        onRequestHide?()
        await settle()
        let quick = FileShelfReviewDrag(urls: [first.url])
        checks.append(("notch_accepts_original_url", receiver.draggingEntered(quick) == .copy && receiver.performDragOperation(quick)))
        await settle()
        checks.append(("notch_capture_stays_hidden_and_keeps_draft", !panel.isVisible && !panelState.fileShelfPreview && model.items.first?.id == first.id && inspirationViewModel.text == "文件中转站回归测试草稿"))
        checks.append(("notch_success_label", drag.notchFeedback.feedback.stage.label == "已收录至中转站"))
        var feedbackPhases: [NotchFeedbackPhase] = []
        for _ in 0..<400 { drag.notchFeedback.advance(0.01); feedbackPhases.append(drag.notchFeedback.phase) }
        checks.append(("notch_success_rim_and_cleanup", feedbackPhases.contains(.glow) && feedbackPhases.contains(.flash) && drag.notchFeedback.phase == .idle))
        show(); debugShowFileShelf(); await settle()
        if let nextGrid = findGrid(panel.contentView), let nextOwner = nextGrid.owner {
            let next = FileShelfReviewDrag(urls: [first.url])
            checks.append(("grid_drop_accepted", nextOwner.collectionView(nextGrid, acceptDrop: next, indexPath: IndexPath(item: model.items.count, section: 0), dropOperation: .before)))
            await settle()
            checks.append(("grid_drop_stays_open_at_position", panel.isVisible && model.items.last?.id == first.id))
        }
        model.kind = .image; model.date = .yesterday
        let second = FileShelfReviewDrag(urls: [first.url]); _ = drag.enter(second); drag.cancel()
        checks.append(("cancel_preserves_shelf_filters", !panelState.fileShelfPreview && panelState.selectedTab == .fileShelf && model.kind == .image && model.date == .yesterday))
        model.resetFilters()
        drag.startInternal([first.id]); drag.endInternal(.copy)
        checks.append(("external_handoff_hides_without_removing", !panel.isVisible && model.items.contains { $0.id == first.id }))
        show(); debugShowFileShelf(); await settle()
        model.kind = .image; model.confirmingClear = true
        await settle(); try debugCapturePromptPanel(to: output.appendingPathComponent("clear-confirmation.png"))
        checks.append(("clear_confirmation_protects_all_records", !drag.canReceive && !prepareForDismissal()))
        model.confirmingClear = false; model.resetFilters()
        let report = checks.map { ["name": $0.0, "passed": $0.1] as [String: Any] }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("checks.json"))
        for (name, passed) in checks { print("FILE_SHELF_REVIEW \(name)=\(passed)") }
        print("FILE_SHELF_REVIEW passed=\(checks.filter(\.1).count)/\(checks.count)"); fflush(stdout)
        panelState.preferences.reduceMotion = false
        return checks.allSatisfy(\.1)
    }

    func debugShowFileShelf() { automaticDismissalEnabled = false; requestSelectTab(.fileShelf) }

    func debugLibraryMotionProbe(output: URL) async throws -> Bool {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = present()
        var checks: [(String, Bool)] = []
        var sequences: [[String: Any]] = []
        for (appearance, scale): (PanelAppearance, Double) in [(.dark, 0.85), (.dark, 1.0), (.dark, 1.2), (.light, 1.0)] {
            let screen = NSScreen.main!.frame
            let size = CGSize(width: 1470 * scale, height: 956 * scale)
            let metrics = ScreenMetrics(frame: .init(x: screen.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height), auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, statusBarThickness: 32)
            currentMetrics = metrics
            panelState.update(metrics: metrics)
            panelState.preferences.appearance = appearance
            panelState.preferences.reduceMotion = false
            let tabs: [PanelTab] = ProcessInfo.processInfo.environment["JOTBLOOM_SHELF_RESIZE_ONLY"] == "1" ? [.fileShelf] : [.clipboard, .prompts, .inspirationLibrary, .fileShelf]
            for tab in tabs {
                requestSelectTab(tab); debugSetExpanded(false)
                try await Task.sleep(nanoseconds: 500_000_000)
                let prefix = tab == .clipboard ? "clipboard" : tab == .prompts ? "prompt" : tab == .fileShelf ? "shelf" : "library"
                let kind: LibraryLayoutMetrics.ContentKind = tab == .clipboard ? .clipboard : tab == .prompts ? .prompts : tab == .fileShelf ? .files : .inspirations
                for expanding in [true, false] {
                    let name = "\(appearance.rawValue)-\(Int(scale * 100))-\(prefix)-\(expanding ? "expand" : "collapse")"
                    var frames: [[String: Any]] = []
                    var heights: [CGFloat] = []
                    let start = ProcessInfo.processInfo.systemUptime
                    let inset = panelState.notchHeight + (tab == .fileShelf ? 80 : 46)
                    let before = LibraryLayoutMetrics(size: .init(width: panel.frame.width - 24, height: panel.frame.height - inset), expanded: !expanding, kind: kind)
                    debugSetExpanded(expanding)
                    checks.append((name + "-first-frame", panelState.libraryResize?.layout(for: kind) == before && panelState.libraryResize?.progress == 0))
                    var reveals: [CGFloat] = []
                    var cardHeights: [CGFloat] = []
                    for index in 0..<16 {
                        let filename = name + "-\(index).png"
                        try debugCapturePromptPanel(to: output.appendingPathComponent(filename))
                        heights.append(panel.frame.height)
                        let live = panelState.libraryResize?.layout(for: kind) ?? LibraryLayoutMetrics(size: .init(width: panel.frame.width - 24, height: panel.frame.height - inset), expanded: expanding, kind: kind)
                        reveals.append(live.sidebarReveal); cardHeights.append(live.cardHeight)
                        frames.append(["file": filename, "time": ProcessInfo.processInfo.systemUptime - start,
                                       "height": panel.frame.height, "progress": panelState.libraryResize?.progress ?? 1])
                        try await Task.sleep(nanoseconds: 30_000_000)
                    }
                    let monotonic = zip(heights, heights.dropFirst()).allSatisfy { expanding ? $0.1 >= $0.0 - 0.1 : $0.1 <= $0.0 + 0.1 }
                    let continuous = zip(reveals, reveals.dropFirst()).allSatisfy { expanding ? $0.1 >= $0.0 : $0.1 <= $0.0 }
                    checks.append((name, monotonic && continuous && panelState.libraryResize == nil && panelState.isExpanded == expanding))
                    if tab == .fileShelf { checks.append((name + "-icons-scale", zip(cardHeights, cardHeights.dropFirst()).allSatisfy { expanding ? $0.1 >= $0.0 : $0.1 <= $0.0 })) }
                    sequences.append(["name": name, "frames": frames])
                }
                debugSetExpanded(true); try await Task.sleep(nanoseconds: 90_000_000)
                debugSetExpanded(false); try await Task.sleep(nanoseconds: 60_000_000)
                debugSetExpanded(true); try await Task.sleep(nanoseconds: 500_000_000)
                checks.append(("\(appearance.rawValue)-\(Int(scale * 100))-\(prefix)-interruption", panelState.libraryResize == nil && panelState.isExpanded && abs(panel.frame.height - 700 * scale) < 0.1))
            }
        }
        panelState.preferences.reduceMotion = true
        debugSetExpanded(false)
        try await Task.sleep(nanoseconds: 20_000_000)
        checks.append(("reduced-motion-no-animation", panelState.libraryResize == nil && panel.frame.height == 300))
        try JSONSerialization.data(withJSONObject: sequences, options: [.prettyPrinted]).write(to: output.appendingPathComponent("motion.json"))
        for (name, passed) in checks { print("MOTION \(name)=\(passed)") }
        print("MOTION passed=\(checks.filter(\.1).count)/\(checks.count)"); fflush(stdout)
        panelState.preferences.reduceMotion = false
        panelState.preferences.appearance = .dark
        _ = present(); requestSelectTab(.prompts)
        return checks.allSatisfy(\.1)
    }

    /// Captures the real SwiftUI hierarchy at the supported size limits using isolated fixtures.
    func debugAdaptiveLibraryProbe(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await fileShelfModel?.waitForPendingOperations()
        panelState.preferences.reduceMotion = true
        var report: [[String: Any]] = []
        for appearance: PanelAppearance in [.dark, .light] {
            panelState.preferences.appearance = appearance
            for scale in [0.85, 1.0, 1.2] {
                for expanded in [false, true] {
                    for tab: PanelTab in [.clipboard, .prompts, .inspirationLibrary] {
                        requestSelectTab(tab)
                        debugSetExpanded(expanded)
                        clipboardViewModel.filterDate(.all)
                        if let first = promptModel?.items.first { promptModel?.select(first.id) }
                        if let first = inspirationLibraryViewModel.items.first { inspirationLibraryViewModel.select(first.id) }
                        panelState.usePointerNavigation()
                        try await Task.sleep(nanoseconds: 250_000_000)
                        let size = NSSize(width: 640 * scale, height: (expanded ? 700 : 300) * scale)
                        panel.setFrame(NSRect(origin: .init(x: 400, y: 60), size: size), display: true)
                        try await Task.sleep(nanoseconds: 250_000_000)
                        let name = "\(appearance.rawValue)-\(Int(scale * 100))-\(tab.rawValue)-\(expanded ? "expanded" : "compact")"
                        try debugCapturePromptPanel(to: output.appendingPathComponent(name + ".png"))
                        let prefix = tab == .clipboard ? "clipboard" : tab == .prompts ? "prompt" : "library"
                        let frames = BloomLayoutDiagnostics.frames
                        let viewport = frames[prefix + "Viewport"] ?? .zero
                        let cards = frames.filter { $0.key.hasPrefix(prefix + "Card.") }.map(\.value)
                        let visible = cards.filter { viewport.insetBy(dx: -1, dy: -1).contains($0) }
                        let columnCount = tab == .clipboard ? clipboardViewModel.gridColumnCount : tab == .prompts ? promptModel?.gridColumnCount ?? 0 : 1
                        var keyboardOK = true
                        if tab == .clipboard, let first = clipboardViewModel.visibleItems.first {
                            clipboardViewModel.select(first.id)
                            debugSendKeyDown(keyCode: UInt16(kVK_DownArrow))
                            keyboardOK = clipboardViewModel.selectedID == clipboardViewModel.visibleItems[min(columnCount, clipboardViewModel.visibleItems.count - 1)].id
                        } else if tab == .prompts, let model = promptModel, let first = model.items.first {
                            model.select(first.id)
                            debugSendKeyDown(keyCode: UInt16(kVK_DownArrow))
                            keyboardOK = model.selectedID == model.items[min(columnCount, model.items.count - 1)].id
                        }
                        let valid = panelState.selectedTab == tab && !visible.isEmpty && keyboardOK && viewport.width > 0 && viewport.maxY <= size.height
                        report.append(["name": name, "valid": valid, "visibleCards": visible.count, "columns": columnCount,
                                       "cardHeight": visible.first?.height ?? 0, "viewport": NSStringFromRect(viewport), "keyboard": keyboardOK])
                        print("ADAPTIVE \(name) visible=\(visible.count) columns=\(columnCount) keyboard=\(keyboardOK) valid=\(valid)")
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("review.json"))
        panelState.preferences.appearance = .dark
        _ = present()
        requestSelectTab(.prompts)
        debugSetExpanded(true)
        try await Task.sleep(nanoseconds: 350_000_000)
        let expandedHeight = panel.frame.height
        debugSetExpanded(false)
        try await Task.sleep(nanoseconds: 350_000_000)
        let compactHeight = panel.frame.height
        print("ADAPTIVE native_expansion=\(expandedHeight > compactHeight) expanded=\(expandedHeight) compact=\(compactHeight)")
        if let first = promptModel?.items.first { promptModel?.select(first.id) }
        print("ADAPTIVE completed=\(report.count) passed=\(report.filter { $0["valid"] as? Bool == true }.count)"); fflush(stdout)
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
        for section in ["general", "tabs", "clipboard", "storage", "ai", "systemPrompt", "about"] {
            panelState.settingsSection = section
            try await Task.sleep(nanoseconds: 180_000_000)
            guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: output.appendingPathComponent(section + ".png")) }
            passed = passed && panelState.isExpanded && view.bounds.height > 300
            if section == "about" {
                func findScroll(_ node: NSView) -> NSScrollView? {
                    if let scroll = node as? NSScrollView { return scroll }
                    return node.subviews.lazy.compactMap { findScroll($0) }.first
                }
                if let scroll = findScroll(view), let document = scroll.documentView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(nanoseconds: 150_000_000)
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: output.appendingPathComponent("about-contacts.png")) }
                }
            }
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

    private func changeAppearance(_ appearance: PanelAppearance, controlRect: NSRect) {
        guard appearance != panelState.preferences.appearance else { return }
        appearanceReveal?.removeFromSuperview(); appearanceReveal = nil
        guard !panelState.reducesMotion, panel.isVisible, let content = panel.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            panelState.preferences.appearance = appearance; return
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let image = NSImage(size: content.bounds.size); image.addRepresentation(bitmap)
        let rect = content.convert(controlRect, from: nil)
        let origin = NSPoint(x: rect.minX + (appearance == .dark ? 39 : 121), y: rect.midY)
        let reveal = BloomThemeRevealView(frame: content.bounds, image: image, origin: origin, controls: rect)
        content.addSubview(reveal, positioned: .above, relativeTo: nil)
        appearanceReveal = reveal
        panelState.preferences.appearance = appearance
        DispatchQueue.main.async { [weak self, weak reveal] in
            guard let self, let reveal, self.appearanceReveal === reveal else { return }
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            reveal.start { [weak self, weak reveal] in
                reveal?.removeFromSuperview()
                if self?.appearanceReveal === reveal { self?.appearanceReveal = nil }
            }
        }
    }

    func beginFileShelfPreview() {
        shelfPreviousExpansion = panelState.isExpanded
        shelfPreviousPreview = panelState.fileShelfPreview
        panelState.fileShelfPreview = true
        panelState.expand()
    }
    func finishFileShelfPreview(cancelled: Bool, close: Bool) {
        if cancelled {
            panelState.fileShelfPreview = shelfPreviousPreview
            if !shelfPreviousExpansion { panelState.collapse() }
        }
        // Keep the temporary route until dismissal so an unrelated unfinished editor
        // is preserved, rather than being flushed by a successful quick drop.
    }

    var isPanelKeyWindow: Bool {
        panel.isKeyWindow
    }

    var reducesShelfMotion: Bool { panelState.reducesMotion }

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
        panelState.libraryResize = nil
        currentMetrics = metrics
        expansionChangesAnimated = false
        panelState.fileShelfPreview = false
        panelState.resetForPresentation()
        panelState.update(metrics: metrics)
        expansionChangesAnimated = true

        closingVisual?.close()
        closingVisual = nil
        let finalFrame = PanelGeometry.panelFrame(for: metrics, expanded: panelState.isExpanded)
        panel.alphaValue = panelState.reducesMotion ? 1 : 0
        panel.setFrame(panelState.reducesMotion ? finalFrame : finalFrame.offsetBy(dx: 0, dy: 8), display: true)
        panel.appearance = NSAppearance(named: panelState.preferences.appearance == .dark ? .darkAqua : .aqua)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        panel.orderFrontRegardless()
        panelState.setPresented(true)
        if !fileDragActive { panel.makeKey(); completeTabSelection(panelState.selectedTab) }
        if !panelState.reducesMotion {
            animatePanel(to: finalFrame, duration: 0.46, curve: (0.18, 0.88, 0.24, 1.035), fadeIn: true)
        }

        logger.debug("Panel presented on a \(Int(screen.frame.width), privacy: .public) by \(Int(screen.frame.height), privacy: .public) point screen")
        return true
    }

    func prepareForDismissal() -> Bool {
        guard !fileDragActive, fileShelfModel?.busy != true, fileShelfModel?.confirmingClear != true else { return false }
        guard settingsModel?.confirmingClear != true else { return false }
        if panelState.fileShelfPreview { return true }
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
        let preservingEditor = panelState.fileShelfPreview
        settingsModel?.recordingShortcut = false
        promptModel?.panelDismissed()
        panelState.fileShelfPreview = false
        focusEventGeneration &+= 1
        restoringSystemFocus = false
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        appearanceReveal?.removeFromSuperview(); appearanceReveal = nil
        animateDismissalVisual()
        detailTransitionInProgress = false
        if !preservingEditor {
            inspirationLibraryViewModel.resetForPanelDismissal()
            globalSearchViewModel.resetForPanelDismissal()
        }
        panel.orderOut(nil)
        panelState.setPresented(false)
        expansionChangesAnimated = false
        panelState.resetForPresentation()
        expansionChangesAnimated = true
        logger.debug("Panel dismissed")
    }

    func close() {
        expansionUpdateGeneration &+= 1
        panelState.setPresented(false)
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
              panel.isVisible, !panel.isKeyWindow, systemInteractionDepth == 0, !fileDragActive,
              !restoringSystemFocus, settingsModel?.maintaining != true else { return }
#if DEBUG
        guard automaticDismissalEnabled else { return }
#endif
        let expected = focusEventGeneration
        DispatchQueue.main.async { [weak self] in
            // A queued resign is obsolete once focus returned or a system operation started.
            guard let self, focusEventGeneration == expected,
                  panel.isVisible, !panel.isKeyWindow, systemInteractionDepth == 0, !fileDragActive,
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
        panel.hasShadow = false
        // The system shadow adds a uniform bright rim. Draw our edge and shadow separately.
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
        panel.appearance = NSAppearance(named: panelState.preferences.appearance == .dark ? .darkAqua : .aqua)
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if panelState.fileShelfPreview { onRequestHide?(); return }
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
            self?.panelState.selectedTab == .chat && self?.panelState.fileShelfPreview == false && self?.panelState.isSettingsOpen == false
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
            guard self?.panelState.fileShelfPreview == true || self?.promptModel?.detailID == nil else { return }
            self?.panelState.collapse()
        }
        panel.isClipboardActive = { [weak self] in
            (self?.panelState.selectedTab == .clipboard || (self?.panelState.selectedTab == .prompts && self?.promptModel?.editingID == nil && self?.promptModel?.detailID == nil))
                && self?.panelState.fileShelfPreview == false && self?.panelState.isSettingsOpen == false && self?.clipboardViewModel.confirmingClear == false
        }
        panel.isInspirationActive = { [weak self] in
            self?.panelState.selectedTab == .inspiration
                && self?.panelState.fileShelfPreview == false && self?.panelState.isSettingsOpen == false && self?.clipboardViewModel.confirmingClear == false
        }
        panel.isInspirationLibraryListActive = { [weak self] in
            self?.panelState.selectedTab == .inspirationLibrary
                && self?.panelState.fileShelfPreview == false && self?.panelState.isSettingsOpen == false && self?.clipboardViewModel.confirmingClear == false
                && self?.isInspirationDetailVisible == false
        }
        panel.isInspirationLibraryDetailActive = { [weak self] in
            self?.isInspirationDetailVisible == true && self?.panelState.fileShelfPreview == false
        }
        panel.isGlobalSearchActive = { [weak self] in
            self?.panelState.selectedTab == .globalSearch
                && self?.panelState.fileShelfPreview == false && self?.panelState.isSettingsOpen == false && self?.clipboardViewModel.confirmingClear == false
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
            if self?.panelState.selectedTab == .prompts { self?.promptModel?.moveGridSelection(rows: offset); return }
            self?.clipboardViewModel.moveGridSelection(rows: offset)
            self?.clipboardViewModel.requestListFocus()
        }
        panel.onMoveClipboardHorizontalSelection = { [weak self] offset in
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
                onExternalLinkOpened: { [weak self] in self?.onRequestHide?() },
                settingsModel: settingsModel,
                promptModel: promptModel,
                chatModel: chatModel,
                fileShelfModel: fileShelfModel,
                fileShelfDrag: fileShelfDrag,
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
        if fileDragActive, event.keyCode == UInt16(kVK_Escape) { fileShelfDrag?.cancel(); return true }
        if fileShelfModel?.confirmingClear == true {
            if event.keyCode == UInt16(kVK_Escape) { fileShelfModel?.confirmingClear = false; return true }
            return ![UInt16(kVK_Tab), UInt16(kVK_Return), UInt16(kVK_Space)].contains(event.keyCode)
        }
        if panelState.fileShelfPreview || (!panelState.isSettingsOpen && panelState.selectedTab == .fileShelf) {
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" { fileShelfModel?.selectAll(); return true }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { Task { await fileShelfModel?.undo() }; return true }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) { Task { await fileShelfModel?.removeSelection() }; return true }
        }
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
        guard !fileDragActive, fileShelfModel?.busy != true, fileShelfModel?.confirmingClear != true else { return }
        if panelState.fileShelfPreview && tab == panelState.selectedTab { panelState.fileShelfPreview = false; return }
        guard settingsModel?.allowLeavingPrompt() != false, chatModel?.canLeaveChat() != false else { return }
        guard chatModel?.confirmingDelete != true else { return }
        if tab != panelState.selectedTab { chatModel?.cancelAuthorization() }
        guard !clipboardViewModel.confirmingClear, !clipboardViewModel.isClearing else { return }
        guard promptModel?.flushEdit() != false else { return }
        if tab != .prompts, promptModel?.detailID != nil { _ = promptModel?.closeEditor() }
        if panelState.selectedTab == .prompts, tab != .prompts { promptModel?.panelDismissed() }
        guard settingsModel?.maintaining != true else { return }
        guard !detailTransitionInProgress else { return }
        panelState.fileShelfPreview = false
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
            case .fileShelf: Task { await fileShelfModel?.refresh() }
            case .inspiration:
                inspirationViewModel.requestInputFocus()
            case .clipboard:
                clipboardViewModel.requestListFocus()
            case .prompts:
                promptModel?.activate()
            case .chat:
                panelState.expand()
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
        case .fileShelf: Task { await fileShelfModel?.refresh() }
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

    private var usesLibraryResize: Bool {
        panelState.fileShelfPreview || (!panelState.isSettingsOpen && !isInspirationDetailVisible &&
            (panelState.selectedTab == .clipboard || panelState.selectedTab == .inspirationLibrary ||
             panelState.selectedTab == .fileShelf || (panelState.selectedTab == .prompts && promptModel?.detailID == nil)))
    }

    @discardableResult
    private func prepareLibraryResize(expanded: Bool, wasExpanded: Bool) -> Bool {
        guard usesLibraryResize, panelState.isPresented, !panelState.reducesMotion,
              let metrics = currentMetrics else { return false }
        let frame = PanelGeometry.panelFrame(for: metrics, expanded: expanded)
        let isShelf = panelState.fileShelfPreview || panelState.selectedTab == .fileShelf
        let inset = panelState.notchHeight + (isShelf ? 80 : 46)
        frameAnimationTimer?.invalidate(); frameAnimationTimer = nil
        panelState.libraryResize = LibraryLayoutTransition(
            fromSize: .init(width: panel.frame.width - 24, height: panel.frame.height - inset),
            toSize: .init(width: frame.width - 24, height: frame.height - inset),
            wasExpanded: wasExpanded, expanded: expanded, previous: panelState.libraryResize)
        return true
    }

    private func resizePanel(expanded: Bool, animated: Bool, wasExpanded: Bool? = nil, transitionPrepared: Bool = false) {
        guard let metrics = currentMetrics else { return }
        let frame = PanelGeometry.panelFrame(for: metrics, expanded: expanded)
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil

        guard animated, panel.isVisible, !panelState.reducesMotion else {
            panelState.libraryResize = nil
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            return
        }

        let isLibrary = usesLibraryResize
        if isLibrary {
            if !transitionPrepared { prepareLibraryResize(expanded: expanded, wasExpanded: wasExpanded ?? panelState.isExpanded) }
        } else { panelState.libraryResize = nil }
        animatePanel(to: frame, duration: isLibrary ? 0.40 : 0.36, curve: isLibrary ? (0.30, 0.05, 0.25, 1) : (0.22, 1, 0.36, 1))
    }

    /// Interruptible frame interpolation. NSWindow.animator can finish an obsolete frame
    /// after a hide/show; this single owner always starts from the current visual frame.
    private func animatePanel(to target: NSRect, duration: Double,
                              curve: (Double, Double, Double, Double), fadeIn: Bool = false) {
        frameAnimationTimer?.invalidate()
        let initial = panel.frame
        let initialAlpha = panel.alphaValue
        // A resize may interrupt presentation (for example, a file hovering over
        // the notch). Continue its fade instead of freezing a transparent window.
        let restoresOpacity = fadeIn || initialAlpha < 1
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
                let eased = Self.cubicProgress(progress, curve: curve)
                func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
                self.panel.setFrame(NSRect(x: mix(initial.minX, target.minX), y: mix(initial.minY, target.minY),
                                      width: mix(initial.width, target.width), height: mix(initial.height, target.height)), display: true)
                if self.panelState.libraryResize != nil { self.panelState.libraryResize?.progress = eased }
                if restoresOpacity { self.panel.alphaValue = min(1, mix(initialAlpha, 1)) }
                if progress >= 1 {
                    timer.invalidate()
                    self.frameAnimationTimer = nil
                    self.panel.setFrame(target, display: true)
                    self.panel.alphaValue = 1
                    self.panelState.libraryResize = nil
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
        guard !fileDragActive, fileShelfModel?.busy != true, fileShelfModel?.confirmingClear != true else { return }
        panelState.fileShelfPreview = false
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
        guard panel.isVisible, panel.alphaValue > 0, !panelState.reducesMotion,
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
        ghost.hasShadow = false
        ghost.backgroundColor = .clear
        ghost.ignoresMouseEvents = true
        ghost.level = panel.level
        ghost.collectionBehavior = panel.collectionBehavior
        let imageView = NSImageView(frame: view.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        ghost.contentView = imageView
        ghost.alphaValue = panel.alphaValue
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
    private var softShadowWindow: NSWindow?
    override var alphaValue: CGFloat { didSet { softShadowWindow?.alphaValue = alphaValue } }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        softShadowWindow?.setFrame(frame.insetBy(dx: -18, dy: -18), display: flag)
    }
    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        if softShadowWindow == nil {
            let shadow = PanelShadowWindow(contentRect: frame.insetBy(dx: -18, dy: -18), styleMask: .borderless, backing: .buffered, defer: false)
            shadow.isReleasedWhenClosed = false
            shadow.animationBehavior = .none
            shadow.isOpaque = false; shadow.backgroundColor = .clear; shadow.hasShadow = false
            shadow.ignoresMouseEvents = true; shadow.isExcludedFromWindowsMenu = true
            shadow.level = level; shadow.collectionBehavior = collectionBehavior
            shadow.contentView = PanelDropShadowView(frame: .zero)
            softShadowWindow = shadow
        }
        // AppKit can detach an ordered-out child; restore the relationship on every show.
        if let shadow = softShadowWindow, shadow.parent !== self { addChildWindow(shadow, ordered: .below) }
        softShadowWindow?.setFrame(frame.insetBy(dx: -18, dy: -18), display: true)
        softShadowWindow?.alphaValue = alphaValue
        softShadowWindow?.order(.below, relativeTo: windowNumber)
    }
    override func orderOut(_ sender: Any?) {
        softShadowWindow?.orderOut(nil)
        super.orderOut(sender)
    }
    override func close() {
        if let shadow = softShadowWindow { removeChildWindow(shadow); shadow.close(); softShadowWindow = nil }
        super.close()
    }

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
    var onMoveClipboardHorizontalSelection: ((Int) -> Void)?
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
            case kVK_LeftArrow, kVK_RightArrow:
                if isClipboardActive?() == true {
                    onMoveClipboardHorizontalSelection?(Int(event.keyCode) == kVK_LeftArrow ? -1 : 1)
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
    private let edgeView = PanelEdgeView(frame: .zero)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        edgeView.needsDisplay = true
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(BloomTheme.surface).cgColor
        }
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
        if edgeView.superview == nil { addSubview(edgeView) }
        edgeView.frame = bounds
        edgeView.needsDisplay = true
    }
}

/// A square top and rounded bottom, shared by the visible rim and the soft shadow.
private enum PanelOutline {
    static func path(in rect: NSRect, radius: CGFloat = 20) -> CGPath {
        let path = CGMutablePath()
        path.move(to: .init(x: rect.minX, y: rect.maxY))
        path.addLine(to: .init(x: rect.maxX, y: rect.maxY))
        path.addLine(to: .init(x: rect.maxX, y: rect.minY + radius))
        path.addQuadCurve(to: .init(x: rect.maxX - radius, y: rect.minY), control: .init(x: rect.maxX, y: rect.minY))
        path.addLine(to: .init(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(to: .init(x: rect.minX, y: rect.minY + radius), control: .init(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private final class PanelEdgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(PanelOutline.path(in: bounds.insetBy(dx: 0.5, dy: 0.5), radius: 19.5))
        context.setLineWidth(1)
        context.replacePathWithStrokedPath(); context.clip()
        // Bottom and bottom corners retain their rim; the upper edge is fully clear.
        let rim = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.20) : NSColor.black.withAlphaComponent(0.12)
        NSGradient(colorsAndLocations: (rim, 0), (rim, 0.10),
                   (rim.withAlphaComponent(0), 0.96), (rim.withAlphaComponent(0), 1))?.draw(in: bounds, angle: 90)
        context.restoreGState()
    }
}

private final class PanelDropShadowView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Keep the panel interior transparent: its fade-in must not reveal a black plate.
        context.addRect(bounds)
        context.addPath(PanelOutline.path(in: bounds.insetBy(dx: 18, dy: 18)))
        context.clip(using: .evenOdd)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = .init(width: 0, height: -4)
        shadow.set()
        context.addPath(PanelOutline.path(in: bounds.insetBy(dx: 18, dy: 18)))
        context.setFillColor(NSColor.black.cgColor); context.fillPath()
        context.restoreGState()
    }
}

/// Shadow padding intentionally extends past the screen edge with its parent panel.
private final class PanelShadowWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Previous circular reveal, with a rounded selector opening and slightly longer duration.
private final class BloomThemeRevealView: NSView {
    private let oldImage = NSImageView()
    private let circleMask = CAShapeLayer()
    private let controlMask = CAShapeLayer()
    private let origin: NSPoint
    private let controls: NSRect
    private var cleanup: DispatchWorkItem?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(frame: NSRect, image: NSImage, origin: NSPoint, controls: NSRect) {
        self.origin = origin; self.controls = controls
        super.init(frame: frame)
        wantsLayer = true
        oldImage.frame = bounds; oldImage.image = image; oldImage.imageScaling = .scaleAxesIndependently
        oldImage.wantsLayer = true; addSubview(oldImage)
        setAccessibilityHidden(true); oldImage.setAccessibilityHidden(true)
        circleMask.frame = bounds
        circleMask.fillRule = .evenOdd; circleMask.path = path(radius: 0.1)
        oldImage.layer?.mask = circleMask
        // Match the control's continuous corner contour instead of exposing a rectangle.
        controlMask.frame = bounds; controlMask.fillRule = .evenOdd
        let holes = CGMutablePath(); holes.addRect(bounds)
        holes.addPath(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .path(in: controls.insetBy(dx: -4, dy: -4)).cgPath)
        controlMask.path = holes; layer?.mask = controlMask
    }
    required init?(coder: NSCoder) { nil }
    private func path(radius: CGFloat) -> CGPath {
        let path = CGMutablePath(); path.addRect(bounds)
        path.addEllipse(in: NSRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2))
        return path
    }
#if DEBUG
    var debugRadius: CGFloat {
        let current = circleMask.presentation()?.path ?? circleMask.path!
        var curves = [CGPoint]()
        current.applyWithBlock { element in
            if element.pointee.type == .addCurveToPoint { curves.append(element.pointee.points[2]) }
        }
        return curves.map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0
    }
    var debugRoundedControlOpening: Bool {
        let corner = NSPoint(x: controls.minX - 3, y: controls.minY - 3)
        return controlMask.path?.contains(corner, using: .evenOdd) == true
            && controlMask.path?.contains(NSPoint(x: controls.midX, y: controls.midY), using: .evenOdd) == false
    }
#endif
    func start(completion: @escaping () -> Void) {
        let radius = [NSPoint(x: 0, y: 0), .init(x: bounds.width, y: 0), .init(x: 0, y: bounds.height), .init(x: bounds.width, y: bounds.height)]
            .map { hypot($0.x - origin.x, $0.y - origin.y) }.max()! + 2
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = path(radius: 0.1); animation.toValue = path(radius: radius)
        let duration = 1.50
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.30, 1)
        circleMask.path = path(radius: radius); circleMask.add(animation, forKey: "reveal")
        let work = DispatchWorkItem(block: completion); cleanup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02, execute: work)
    }
    deinit { cleanup?.cancel() }
}
