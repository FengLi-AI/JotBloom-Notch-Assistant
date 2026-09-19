import AppKit

@MainActor
final class CodexCompletionMonitor {
    var onCompletion: (CodexCompletion) -> Void = { _ in }
    var onForeground: (Bool) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onDecision: (CodexCompletion, Bool) -> Void = { _, _ in }
    private let queue = DispatchQueue(label: "com.jotbloom.companion.codex", qos: .utility)
    private var timer: Timer?
    private var reader: CodexCompletionReader?
    private var generation = UUID()
    private var polling = false
    private var foreground = CodexForegroundHistory()
    private var notifyingHost: CodexHost?

    func start(root: URL) {
        stop()
        foreground = CodexForegroundHistory()
        foreground.record(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let next = CodexCompletionReader(root: root); reader = next
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        poll()
    }
    func stop() {
        timer?.invalidate(); timer = nil; generation = UUID(); reader = nil; polling = false
        notifyingHost = nil; onForeground(true)
    }
    func appChanged() {
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        foreground.record(current)
        if let notifyingHost { onForeground(current.map { notifyingHost.bundleIDs.contains($0) } ?? true) }
    }
    private func poll() {
        guard !polling, let reader else { return }
        polling = true; let token = generation
        queue.async { [weak self] in
            let events = reader.poll()
            let status = reader.failed ? "暂时无法读取 Codex 完成事件，请检查目录权限。" : !reader.available ? "未找到 Codex 会话目录，可在下方重新选择。" : reader.hasSessions ? "已连接本机 Codex，等待下一轮完成。" : "已连接目录，等待 Codex 创建会话。"
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.polling = false; self.onStatus(status)
                for event in events {
                    let shouldNotify = self.foreground.shouldNotify(event)
                    self.onDecision(event, shouldNotify)
                    guard shouldNotify else { continue }
                    self.notifyingHost = event.host; self.onForeground(false); self.onCompletion(event)
                }
            }
        }
    }
}
