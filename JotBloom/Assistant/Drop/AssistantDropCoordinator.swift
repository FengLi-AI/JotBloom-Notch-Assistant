import AppKit
import JotBloomCore

@MainActor
final class AssistantDropCoordinator {
    let panel = AssistantDropPanel()
    var allowed: () -> Bool = { false }
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var receive: ((String, [AssistantAttachment], String) -> Void)?
    var onFinish: () -> Void = {}
    private(set) var session = AssistantDropSession()
    private var grace: Task<Void, Never>?
    private var close: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    private var releaseMonitor: Any?
    private weak var origin: NotchDropView?
    var active: Bool { session.sequence != nil }
    var destinationFrame: CGRect { active ? panel.frame : .zero }

    init() { panel.destination.coordinator = self }
    func enterNotch(_ sender: NSDraggingInfo, origin: NotchDropView) {
        guard allowed(), sender.draggingSourceOperationMask.contains(.copy), let notch = origin.window?.frame else { return }
        let wasActive = active
        guard session.begin(sender.draggingSequenceNumber) else { return }
        self.origin = origin
        origin.capture?.feedback.alphaValue = 1
        origin.fileShelf?.notchFeedback.feedback.alphaValue = 1
        grace?.cancel(); grace = nil; close?.cancel(); close = nil
        panel.bubbleAppearance.hovering = false; panel.bubbleAppearance.reduced = reducesMotion()
        panel.locate(notch: notch); panel.ignoresMouseEvents = false
        if !panel.isVisible { panel.orderFrontRegardless() }
        if !wasActive {
            opening?.cancel(); panel.bubbleAppearance.visible = false
            opening = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
                guard let self, self.active else { return }
                self.panel.bubbleAppearance.visible = true
            }
        }
        if releaseMonitor == nil {
            releaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
                self?.leave()
            }
        }
    }
    func canAccept(_ sender: NSDraggingInfo) -> Bool {
        guard allowed(), session.sequence == sender.draggingSequenceNumber,
              sender.draggingSourceOperationMask.contains(.copy),
              panel.destination.bounds.contains(panel.destination.convert(sender.draggingLocation, from: nil)) else { return false }
        return !FileShelfDragController.urls(sender.draggingPasteboard).isEmpty || origin?.text(from: sender.draggingPasteboard) != nil
    }
    func enterBubble(_ sender: NSDraggingInfo) -> Bool {
        guard canAccept(sender) else { return false }
        grace?.cancel(); grace = nil
        panel.bubbleAppearance.hovering = true
        origin?.capture?.feedback.alphaValue = 0.35
        origin?.fileShelf?.notchFeedback.feedback.alphaValue = 0.35
        return true
    }
    func leave() {
        guard active else { return }
        grace?.cancel()
        grace = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            self?.cancel()
        }
    }
    func accept(_ sender: NSDraggingInfo) -> Bool {
        if session.destination(for: sender.draggingSequenceNumber) == .assistant { return true }
        guard canAccept(sender) else { return false }
        let files = FileShelfDragController.urls(sender.draggingPasteboard).map(AssistantAttachment.file)
        let input = files.isEmpty ? origin?.text(from: sender.draggingPasteboard) ?? "" : ""
        guard !input.isEmpty || !files.isEmpty, let receive,
              session.commit(sender.draggingSequenceNumber, to: .assistant) else { return false }
        finish(); receive(input, files, UUID().uuidString)
        return true
    }
    func notchCommitted(_ sequence: Int) {
        _ = session.commit(sequence, to: .notch); finish(leaveOrigin: false)
    }
    func end(sequence: Int) {
        // A previous destination may receive draggingEnded before the new one
        // receives performDragOperation. Leave its 180 ms handoff window intact.
        if session.sequence == sequence { leave() }
    }
    func cancel() { session.cancel(); finish() }
    private func finish(leaveOrigin: Bool = true) {
        grace?.cancel(); grace = nil; opening?.cancel(); opening = nil
        if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor); self.releaseMonitor = nil }
        origin?.capture?.feedback.alphaValue = 1
        origin?.fileShelf?.notchFeedback.feedback.alphaValue = 1
        if leaveOrigin { origin?.capture?.leave(); origin?.fileShelf?.leaveNotch() }
        origin = nil
        panel.ignoresMouseEvents = true; panel.bubbleAppearance.hovering = false; panel.bubbleAppearance.visible = false
        close?.cancel()
        close = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
            self?.panel.orderOut(nil)
        }
        DispatchQueue.main.async { [weak self] in self?.onFinish() }
    }
    func stop() { cancel(); close?.cancel(); panel.orderOut(nil); panel.close() }
}
