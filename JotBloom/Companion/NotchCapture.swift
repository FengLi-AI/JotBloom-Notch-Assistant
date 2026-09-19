import AppKit
import JotBloomCore

/// Only this view, inside the host's physical-notch window, accepts a drop.
/// The larger feedback window is entirely click/drag transparent.
@MainActor
final class NotchDropView: NSView {
    weak var capture: NotchCaptureController?
    var onActivate: (() -> Void)?
    private var sequence: Int?
    private var cachedText: String?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string, NSPasteboard.PasteboardType("public.utf8-plain-text")])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if HotZoneClickPolicy.shouldActivate(buttonNumber: event.buttonNumber, clickCount: event.clickCount) { onActivate?() }
    }
    func text(from board: NSPasteboard) -> String? {
        guard board.types?.contains(.fileURL) != true,
              let text = board.string(forType: .string) ?? board.string(forType: .init("public.utf8-plain-text")),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        if sequence != sender.draggingSequenceNumber {
            sequence = sender.draggingSequenceNumber; cachedText = text(from: sender.draggingPasteboard)
        }
        return capture?.canReceive == true && bounds.contains(convert(sender.draggingLocation, from: nil)) && cachedText != nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { capture?.leave(); return [] }
        capture?.hover(); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { capture?.leave(); sequence = nil; cachedText = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender), let text = cachedText else { return false }
        return capture?.accept(text, sequence: sender.draggingSequenceNumber) == true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { capture?.leave(); sequence = nil; cachedText = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { capture?.leave(); sequence = nil; cachedText = nil }
}

@MainActor
final class NotchCaptureController {
    let feedback = NotchFeedbackPanel()
    var enabled = true
    var presentationAllowed = true { didSet { if !presentationAllowed { conceal() } } }
    var reduced = false
    var canWrite: () -> Bool = { false }
    var save: (String) async throws -> Void = { _ in }
    var reserve: () -> Void = {}
    var release: () -> Void = {}
    var received: () -> Void = {}
    var hovering: (Bool) -> Void = { _ in }
    var statusChanged: (String?) -> Void = { _ in }
    private(set) var phase: NotchFeedbackPhase = .idle
    private(set) var pending = 0
    private var successes = 0
    private var failure: String?
    private var dismissed = false
    private var stopped = false
    private var sequences: [Int] = []
    private var timer: Timer?
    private var lastTime = 0.0
    private var elapsed = 0.0
    private var height = 0.0
    private var velocity = 0.0
    var canReceive: Bool { !stopped && enabled && presentationAllowed && canWrite() && pending < 16 }

    func locate(_ notch: CGRect) { feedback.locate(notch) }
    func hover() {
        guard canReceive else { return }
        hovering(true)
        if phase == .idle || phase == .cancel || phase == .failure { enter(.hover) }
    }
    func leave() {
        hovering(false)
        if phase == .hover { enter(.cancel) }
    }
    @discardableResult
    func accept(_ text: String, sequence: Int) -> Bool {
        guard canReceive else { return false }
        if sequences.contains(sequence) { return true }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        sequences.append(sequence); if sequences.count > 64 { sequences.removeFirst() }
        if pending == 0 && [.idle, .hover, .cancel, .failure].contains(phase) { successes = 0; failure = nil }
        pending += 1; dismissed = false; hovering(false); reserve(); enter(.ack)
        let write = save
        Task { [weak self] in
            do { try await write(text); self?.saved(error: nil) }
            catch { self?.saved(error: error) }
        }
        return true
    }
    private func saved(error: Error?) {
        pending = max(0, pending - 1)
        if let error {
            failure = (error as? PromptError) == .duplicateInspiration ? "这条灵感已收录" : "未能收录，请重试"
            statusChanged((error as? PromptError) == .duplicateInspiration ? "这条灵感已在库中，无需重复收录。" : "拖入收录失败：" + error.localizedDescription)
        } else { successes += 1; if failure == nil { statusChanged("已收录到灵感库") } }
        guard !stopped else { return }
        if !presentationAllowed || !enabled || dismissed { finish(notify: !dismissed) }
        else if timer == nil { enter(.ack) }
    }
    func conceal() {
        hovering(false); timer?.invalidate(); timer = nil
        phase = .idle; height = 0; velocity = 0; feedback.orderOut(nil)
        finish(notify: true)
    }
    /// Dismiss visual acknowledgement without cancelling an accepted write.
    func dismiss() { dismissed = true; conceal(); release() }
    func stop() { stopped = true; dismissed = true; conceal(); feedback.close() }
    private func finish(notify: Bool) {
        guard pending == 0 else { return }
        release()
        if successes > 0 && notify && !stopped { successes = 0; received() }
        else { successes = 0 }
    }
    private func enter(_ next: NotchFeedbackPhase) {
        phase = next; elapsed = 0
        if next == .idle {
            timer?.invalidate(); timer = nil; feedback.orderOut(nil); return
        }
        guard presentationAllowed, enabled else { conceal(); return }
        if !feedback.isVisible { feedback.orderFrontRegardless() }
        paint()
        if timer == nil {
            lastTime = ProcessInfo.processInfo.systemUptime
            let next = Timer(timeInterval: reduced ? 1.0 / 30 : 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(next, forMode: .common); timer = next
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime, dt = min(0.1, now - lastTime)
        lastTime = now; advance(dt)
    }
    func advance(_ dt: Double) {
        elapsed += dt
        let target = [.hover, .ack, .failure].contains(phase) ? 1.0 : 0.0
        if reduced { height = target; velocity = 0 }
        else {
            var remaining = dt
            while remaining > 0 {
                let step = min(remaining, 1.0 / 120)
                velocity += ((target - height) * 250 - velocity * 26) * step
                height += velocity * step; remaining -= step
            }
        }
        switch phase {
        case .ack where pending == 0 && elapsed >= 0.55: enter(failure == nil ? .absorb : .failure)
        case .absorb where elapsed >= (reduced ? 0.18 : 0.82): enter(.glow)
        case .glow where elapsed >= (reduced ? 0.28 : 0.92): enter(.flash)
        case .flash where elapsed >= (reduced ? 0.04 : 0.32): finish(notify: !dismissed); enter(.idle)
        case .failure where elapsed >= 2.4: finish(notify: !dismissed); enter(.cancel)
        case .cancel where elapsed >= 0.24: height = 0; enter(.idle)
        default: break
        }
        paint()
    }
    private func paint() {
        feedback.stage.phase = phase; feedback.stage.elapsed = elapsed
        feedback.stage.expansion = height; feedback.stage.reduced = reduced
        feedback.stage.label = phase == .failure ? (failure ?? "未能收录，请重试") : phase == .ack || phase == .absorb ? "收到，正在收录" : "松手即可收录灵感"
        feedback.stage.needsDisplay = true
    }
}
