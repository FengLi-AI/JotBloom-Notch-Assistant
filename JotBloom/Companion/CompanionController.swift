import AppKit
import JotBloomCore
import SwiftUI

@MainActor
@objc(JotBloomCompanionExtension)
final class JotBloomCompanionExtension: NSObject, ApplicationExtending {
    private var controller: CompanionController?
    required override init() { super.init() }
    var settingsTitle: String { "小伙伴" }
    var settingsView: AnyView {
        if let controller { return AnyView(CompanionSettingsView(model: controller)) }
        return AnyView(Text("小伙伴暂未启动"))
    }
    func start(context: ApplicationExtensionContext) {
        controller = CompanionController(context: context)
        controller?.start()
#if DEBUG
        if let destination = ProcessInfo.processInfo.environment["JOTBLOOM_COMPANION_SMOKE"] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                if let controller = self?.controller {
                    await CompanionSmoke.run(controller: controller, context: context, destination: destination)
                }
            }
        }
#endif
    }
    func panelVisibilityDidChange(_ visible: Bool) { controller?.panelChanged(visible) }
    func openSettings() { controller?.openSettings() }
    func makeHotZoneView(onActivate: @escaping () -> Void) -> NSView? {
        controller?.makeDropView(onActivate: onActivate)
    }
    func stop() { controller?.stop(); controller = nil }
}

@MainActor
final class CompanionController: NSObject, ObservableObject {
    static let characters = [("chuichui", "垂垂"), ("yuntuan", "云团"), ("dujiao", "嘟角"), ("momo", "墨墨"), ("lili", "栗栗"), ("mumu", "暮暮")]
    @Published var enabled: Bool { didSet { persist(); reconcile() } }
    @Published var resident: Bool { didSet { persist(); configure() } }
    @Published var backdrop: Bool { didSet { persist(); configure() } }
    @Published var frequency: Double { didSet { persist(); engine?.action("frequency", frequency) } }
    @Published var preset: String { didSet { persist() } }
    @Published var captureEnabled: Bool { didSet { persist(); refreshCapture() } }
    @Published var codexEnabled: Bool { didSet { persist(); refreshCodex() } }
    @Published var codexDirectory: String { didSet { persist(); refreshCodex() } }
    @Published private(set) var captureStatus: String?
    @Published private(set) var codexStatus = "未开启完成提醒"
    private(set) var capture: NotchCaptureController?
    private let codex = CodexCompletionMonitor()
    private var codexWatching = false
    @Published private(set) var hasNotch = false
    @Published private(set) var issue: String?
    @Published private(set) var isFullScreen = false
    private(set) var engine: NativeCompanionEngine?
    private(set) var overlay: CompanionOverlay?
    private let context: ApplicationExtensionContext
    private let defaults: UserDefaults
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var environmentTimer: Timer?
    private var interval: Double = 0
    private var lastTime: Double = 0
    private var sleeping = false
    private var screenSleeping = false
    private var sessionInactive = false
    private var reduced = false
    private var stopped = true
    private var reducedCheckAt: Double = 0
    private let preferenceKey = "jotbloom.companion.preferences.v1"

    init(context: ApplicationExtensionContext) {
        self.context = context
        // Explicit smoke checks use isolated preferences.
        defaults = context.defaults
        let settings = defaults.dictionary(forKey: preferenceKey) ?? [:]
        enabled = settings["enabled"] as? Bool ?? true
        resident = settings["resident"] as? Bool ?? true
        backdrop = settings["backdrop"] as? Bool ?? true
        frequency = min(100, max(0, settings["frequency"] as? Double ?? 50))
        let saved = settings["preset"] as? String ?? "chuichui"
        preset = Self.characters.contains { $0.0 == saved } ? saved : "chuichui"
        captureEnabled = settings["capture"] as? Bool ?? true
        codexEnabled = settings["codex"] as? Bool ?? true
        codexDirectory = settings["codexDirectory"] as? String ?? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        super.init()
    }

    func start() {
        guard stopped else { return }
        stopped = false
        overlay = CompanionOverlay()
        overlay?.stage.onClick = { [weak self] in
            guard let self else { return }
            if !self.resident { self.capture?.dismiss() }
            self.engine?.action("interact")
        }
        let capture = NotchCaptureController()
        capture.canWrite = context.canSaveInspiration
        capture.save = context.saveInspiration
        capture.reserve = { [weak self] in if self?.enabled == true { self?.engine?.action("reserve") } }
        capture.release = { [weak self] in self?.engine?.action("release") }
        capture.hovering = { [weak self] value in self?.engine?.action("hovering", value) }
        capture.received = { [weak self] in self?.receiveEvent("receive") }
        capture.statusChanged = { [weak self] value in self?.captureStatus = value }
        self.capture = capture
        codex.onCompletion = { [weak self] _ in self?.receiveEvent("notify") }
        codex.onForeground = { [weak self] value in self?.engine?.action("foreground", value) }
        codex.onStatus = { [weak self] value in self?.codexStatus = value }
#if DEBUG
        codex.onDecision = { [weak self] event, allowed in
            self?.recordLiveCheck(["kind": "codex-decision", "host": event.host.rawValue, "notify": allowed,
                                   "foreground": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"])
        }
#endif
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) { $0.refreshEnvironment() }
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { $0.refreshEnvironment() }
        observe(NSWorkspace.didActivateApplicationNotification, center: workspace) { $0.codex.appChanged(); $0.refreshEnvironment() }
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: workspace) { $0.updateReduction() }
        observe(NSWorkspace.willSleepNotification, center: workspace) { $0.sleeping = true; $0.reconcile() }
        observe(NSWorkspace.didWakeNotification, center: workspace) { $0.sleeping = false; $0.refreshEnvironment() }
        observe(NSWorkspace.screensDidSleepNotification, center: workspace) { $0.screenSleeping = true; $0.reconcile() }
        observe(NSWorkspace.screensDidWakeNotification, center: workspace) { $0.screenSleeping = false; $0.refreshEnvironment() }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { $0.sessionInactive = true; $0.reconcile() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { $0.sessionInactive = false; $0.refreshEnvironment() }
        let environment = Timer(timeInterval: 2, target: self, selector: #selector(checkEnvironment), userInfo: nil, repeats: true)
        environment.tolerance = 0.3
        RunLoop.main.add(environment, forMode: .common); environmentTimer = environment
        refreshEnvironment()
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, action: @escaping @MainActor (CompanionController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        observers.append((center, token))
    }

    func stop() {
        stopped = true
        timer?.invalidate(); timer = nil; interval = 0
        environmentTimer?.invalidate(); environmentTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        overlay?.orderOut(nil); overlay?.close(); overlay = nil; engine = nil
        capture?.stop(); capture = nil; codex.stop(); codexWatching = false
    }

    private func persist() {
        defaults.set(["enabled": enabled, "resident": resident, "backdrop": backdrop,
                      "frequency": frequency, "preset": preset, "capture": captureEnabled,
                      "codex": codexEnabled, "codexDirectory": codexDirectory], forKey: preferenceKey)
    }

    private func updateReduction() {
        reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || PanelPreferencesStore(defaults: context.defaults).load().reduceMotion
        engine?.action("reduced", reduced)
        capture?.reduced = reduced
    }

    private func configure() {
        engine?.action("resident", resident)
        if !resident { engine?.action("backdrop", backdrop) }
        engine?.action("panel", context.isPanelVisible())
    }

    private func refreshEnvironment() {
        hasNotch = overlay?.locate() ?? false
        if let overlay, hasNotch { capture?.locate(overlay.notch) }
        isFullScreen = FullScreenDetector().currentState() == .fullScreen
        reconcile()
    }

    @objc private func checkEnvironment() {
        guard !sleeping, !screenSleeping, !sessionInactive else { return }
        let fullScreen = FullScreenDetector().currentState() == .fullScreen
        if fullScreen != isFullScreen { isFullScreen = fullScreen; reconcile() }
    }

    private func reconcile() {
        guard !stopped else { return }
        updateReduction()
        refreshCapture()
        refreshCodex()
        if engine == nil {
            do {
                engine = try NativeCompanionEngine(resident: resident, backdrop: backdrop, frequency: frequency, reduced: reduced)
                issue = nil
            } catch {
                issue = "小伙伴未能启动，请重新打开萌生。"
                return
            }
        }
        // Settings still need character thumbnails when the pet is disabled or
        // the notebook is connected in closed-display mode. No timer runs then.
        guard enabled, hasNotch, !sleeping, !screenSleeping, !sessionInactive, !isFullScreen else {
            timer?.invalidate(); timer = nil; interval = 0; overlay?.orderOut(nil)
            return
        }
        configure()
        if timer == nil { lastTime = ProcessInfo.processInfo.systemUptime; setInterval(1.0 / 60) }
    }

    private func setInterval(_ value: Double) {
        guard interval != value || timer == nil else { return }
        timer?.invalidate(); interval = value
        let next = Timer(timeInterval: value, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        next.tolerance = value > 0.1 ? 0.05 : 0.002
        RunLoop.main.add(next, forMode: .common); timer = next
    }

    @objc private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.25, max(0, now - lastTime)); lastTime = now
        // Includes an in-place full-screen transition without an app activation.
        if now >= reducedCheckAt {
            reducedCheckAt = now + 2
            updateReduction()
            if FullScreenDetector().currentState() == .fullScreen { isFullScreen = true; reconcile(); return }
        }
        guard let overlay, let engine else { return }
        let cursor = NSEvent.mouseLocation
        let gaze = CGPoint(x: (cursor.x - overlay.frame.midX) / 160, y: (overlay.frame.midY - cursor.y) / 160)
        guard let frame = engine.frame(dt: dt, preset: preset, gaze: gaze), engine.lastError == nil else {
            issue = "小伙伴暂时停下了，请重新打开萌生。"
            timer?.invalidate(); timer = nil; interval = 0; overlay.orderOut(nil); return
        }
        overlay.update(frame)
        let resting = ["sleep", "tired"].contains(frame.text("mood")) && frame.text("phase") == "active" && frame.number("elapsed") > 2
        setInterval(frame.text("phase") == "hidden" ? 0.25 : reduced ? 1.0 / 15 : resting ? 1.0 / 24 : frame.text("phase") == "idle" ? 1.0 / 30 : 1.0 / 60)
    }

    func panelChanged(_ visible: Bool) {
        engine?.action("panel", visible)
        refreshCapture()
        if timer != nil { setInterval(1.0 / 60) }
    }

    func preview(_ mood: String = "idle") {
        guard enabled else { return }
        context.hidePanel()
        guard !context.isPanelVisible() else { return }
        engine?.action("panel", false)
        engine?.action("preview", mood)
        if timer != nil { setInterval(1.0 / 60) }
    }

    func thumbnail(_ character: String) -> CGImage? { engine?.thumbnail(character) }
    func openSettings() { context.showSettings() }

    func makeDropView(onActivate: @escaping () -> Void) -> NSView {
        let view = NotchDropView(frame: .zero)
        view.capture = capture; view.onActivate = onActivate
        return view
    }

    private func refreshCapture() {
        capture?.enabled = captureEnabled
        capture?.presentationAllowed = captureEnabled && hasNotch && !context.isPanelVisible() && !sleeping && !screenSleeping && !sessionInactive && !isFullScreen
    }

    private func refreshCodex() {
        let watch = codexEnabled && enabled && !stopped && !sleeping && !screenSleeping && !sessionInactive
        if !watch {
            if codexWatching { codex.stop(); codexWatching = false }
            codexStatus = codexEnabled ? "显示小伙伴后，将自动接收完成提醒。" : "未开启完成提醒"
        } else if !codexWatching {
            codexWatching = true; codex.start(root: URL(fileURLWithPath: codexDirectory, isDirectory: true))
        }
    }

    func chooseCodexDirectory() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.showsHiddenFiles = true; picker.allowsMultipleSelection = false
        picker.message = "选择 Codex 数据目录（通常是主目录中的 .codex，里面应有 sessions 文件夹）。"
        picker.directoryURL = URL(fileURLWithPath: codexDirectory)
        if picker.runModal() == .OK, let url = picker.url {
            codex.stop(); codexWatching = false; codexDirectory = url.path
        }
        context.showSettings()
    }

    func receiveEvent(_ kind: String) {
        guard enabled else { return }
        engine?.action("event", kind)
#if DEBUG
        recordLiveCheck(["kind": kind, "phase": engine?.frame(dt: 0, preset: preset)?.text("phase") ?? "missing"])
#endif
        if timer != nil { setInterval(1.0 / 60) }
    }
#if DEBUG
    private func recordLiveCheck(_ event: [String: Any]) {
        guard let path = ProcessInfo.processInfo.environment["JOTBLOOM_LIVE_CHECK"] else { return }
        let url = URL(fileURLWithPath: path).appendingPathComponent("events.jsonl")
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let file = try? FileHandle(forWritingTo: url) { try? file.seekToEnd(); try? file.write(contentsOf: data); try? file.close() }
    }
#endif
}
