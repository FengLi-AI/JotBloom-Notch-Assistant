import AppKit
import JotBloomCore
import OSLog

@MainActor
final class PasteboardMonitor {
    static let backgroundInterval: TimeInterval = 0.5
    static let visiblePanelInterval: TimeInterval = 0.2

    private let pasteboard: ClipboardPasteboardAccessing
    private let snapshotReader: ClipboardSnapshotReader
    private let sourceProvider: () -> ClipboardSourceApplication
    private let onSnapshot: (ClipboardSnapshot) -> Void
    private let nowUTCms: () -> Int64
    private let workspaceNotificationCenter: NotificationCenter
    private let logger = Logger(
        subsystem: "com.jotbloom.mengsheng",
        category: "clipboard-monitor"
    )

    private var timer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastSeenChangeCount = 0
    private var interval = PasteboardMonitor.backgroundInterval
    private var pauseReasons: Set<Int> = []
    private var isPaused: Bool { !pauseReasons.isEmpty }
    private var userEnabled = true
    private var maintenancePaused = false
    private(set) var isRunning = false

#if DEBUG
    var debugInterval: TimeInterval { interval }
    var debugIsPaused: Bool { isPaused }
    var debugLastSeenChangeCount: Int { lastSeenChangeCount }
#endif

    init(
        pasteboard: ClipboardPasteboardAccessing,
        snapshotReader: ClipboardSnapshotReader? = nil,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        nowUTCms: @escaping () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        },
        sourceProvider: @escaping () -> ClipboardSourceApplication,
        onSnapshot: @escaping (ClipboardSnapshot) -> Void
    ) {
        self.pasteboard = pasteboard
        self.snapshotReader = snapshotReader ?? ClipboardSnapshotReader()
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.nowUTCms = nowUTCms
        self.sourceProvider = sourceProvider
        self.onSnapshot = onSnapshot
    }

    deinit {
        timer?.invalidate()
        for token in notificationTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
    }

    func start() {
        guard !isRunning else { return }
        lastSeenChangeCount = pasteboard.changeCount
        isRunning = true
        installLifecycleObservers()
        scheduleTimer()
        logger.info("Clipboard monitor started")
    }

    func stop() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        for token in notificationTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
        isRunning = false
        logger.info("Clipboard monitor stopped")
    }

    func setPanelVisible(_ isVisible: Bool) {
        let newInterval = isVisible
            ? Self.visiblePanelInterval
            : Self.backgroundInterval
        guard interval != newInterval else { return }
        interval = newInterval
        if isRunning {
            scheduleTimer()
        }
    }

    func advanceBaseline(to changeCount: Int) {
        lastSeenChangeCount = changeCount
    }

    func pollNow() {
        guard isRunning, !isPaused, userEnabled, !maintenancePaused else { return }
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastSeenChangeCount else { return }

        lastSeenChangeCount = currentChangeCount
        guard let snapshot = snapshotReader.readSnapshot(
            from: pasteboard,
            expectedChangeCount: currentChangeCount,
            copiedAtUTCms: nowUTCms(),
            sourceApplication: sourceProvider()
        ) else {
            return
        }
        onSnapshot(snapshot)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard userEnabled, !maintenancePaused else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setUserEnabled(_ enabled: Bool) {
        userEnabled = enabled
        lastSeenChangeCount = pasteboard.changeCount
        if isRunning { scheduleTimer() }
    }

    func setMaintenancePaused(_ paused: Bool) {
        maintenancePaused = paused
        lastSeenChangeCount = pasteboard.changeCount
        if isRunning { scheduleTimer() }
    }

    private func installLifecycleObservers() {
        let pauseNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        let resumeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        for (index, name) in pauseNames.enumerated() {
            notificationTokens.append(
                workspaceNotificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.pauseReasons.insert(index)
                    }
                }
            )
        }
        for (index, name) in resumeNames.enumerated() {
            notificationTokens.append(
                workspaceNotificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.pauseReasons.remove(index)
                        self.pollNow()
                    }
                }
            )
        }
    }
}
