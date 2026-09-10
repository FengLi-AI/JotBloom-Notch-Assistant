import AppKit
import JotBloomCore
import OSLog

@MainActor
final class HotZoneWindowController {
    private let logger = Logger(subsystem: "com.jotbloom.mengsheng", category: "hot-zone")
    private let fullScreenDetector = FullScreenDetector()
    private let onActivate: () -> Void
    private var observerTokens: [NSObjectProtocol] = []
    private var windows: [HotZonePanel] = []
    private var panelVisible = false
    private var started = false

#if DEBUG
    var debugWindowCount: Int { windows.count }
    var debugWindowFrames: [CGRect] { windows.map(\.frame) }

    func debugActivate() {
        onActivate()
    }
#endif

    init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
    }

    func start() {
        guard !started else { return }
        started = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        )
        observerTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        )
        observerTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        )

        refresh()
    }

    func stop() {
        guard started else { return }
        started = false

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for token in observerTokens {
            workspaceCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        closeWindows()
    }

    func setPanelVisible(_ isVisible: Bool) {
        panelVisible = isVisible
        refresh()
    }

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard started else { return }

        let fullScreenState = fullScreenDetector.currentState()
        closeWindows()
        windows = NSScreen.screens.compactMap { screen in
            let metrics = ScreenLocator.metrics(for: screen)
            let hasPhysicalNotch = PanelGeometry.physicalNotchFrame(for: metrics) != nil
            guard HotZoneAvailabilityPolicy.isEnabled(
                panelVisible: panelVisible,
                hasPhysicalNotch: hasPhysicalNotch,
                fullScreenState: fullScreenState
            ) else {
                return nil
            }

            let window = HotZonePanel(frame: PanelGeometry.hotZoneFrame(for: metrics))
            window.onActivate = onActivate
            window.orderFrontRegardless()
            return window
        }
        logger.debug(
            "Hot zones refreshed for \(self.windows.count, privacy: .public) screen(s); panel visible: \(self.panelVisible, privacy: .public)"
        )
    }

    private func closeWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }
}

private final class HotZonePanel: NSPanel {
    var onActivate: (() -> Void)? {
        didSet { clickView.onActivate = onActivate }
    }

    private let clickView = HotZoneClickView(frame: .zero)

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false
        contentView = clickView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HotZoneClickView: NSView {
    var onActivate: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard HotZoneClickPolicy.shouldActivate(
            buttonNumber: event.buttonNumber,
            clickCount: event.clickCount
        ) else {
            return
        }

        let action = onActivate
        DispatchQueue.main.async {
            action?()
        }
    }
}
