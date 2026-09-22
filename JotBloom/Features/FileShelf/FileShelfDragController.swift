import AppKit
import JotBloomCore

/// File references enter either through quiet notch capture or the open native grid.
/// It never takes ownership of the source file or asks the source to move it.
@MainActor
final class FileShelfDragController: ObservableObject {
    let model: FileShelfViewModel
    var enabled: () -> Bool = { true }
    var allowed: () -> Bool = { true }
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    let notchFeedback = NotchCaptureController()
    var onActivity: (Bool) -> Void = { _ in }
    var onExternalHandoff: () -> Void = {}
    var panelFrame: () -> NSRect = { .zero }
    var onHotZoneRefresh: () -> Void = {}
    @Published private(set) var hovering = false
    private(set) var active = false
    private var sequence: Int?
    private var notch = NSRect.zero
    private var committing = false
    private var timer: Timer?
    private var outsideSince: TimeInterval?
    private var priorKind: ShelfFileKind?
    private var priorDate = ClipboardDateFilter.all
    private var priorSelection: Set<UUID> = []
    var internalIDs: Set<UUID> = []
    var internalDrop = false
    init(model: FileShelfViewModel) {
        self.model = model
        notchFeedback.hoverLabel = "松手即可放入中转站"
        notchFeedback.successLabel = "已收录至中转站"
        notchFeedback.failureLabel = { _ in "部分文件未收录，请在中转站查看" }
        notchFeedback.canWrite = { [weak self] in self?.canReceive == true }
        notchFeedback.hovering = { ApplicationExtensionHost.shared.module?.captureFeedback(.hovering($0)) }
        notchFeedback.reserve = { ApplicationExtensionHost.shared.module?.captureFeedback(.reserve) }
        notchFeedback.release = { ApplicationExtensionHost.shared.module?.captureFeedback(.release) }
        notchFeedback.received = { ApplicationExtensionHost.shared.module?.captureFeedback(.received) }
    }
    func stop() { cancel(); notchFeedback.stop() }
    func leaveNotch() { notchFeedback.leave(); cancel() }

    static func urls(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(\.isFileURL)
    }
    var canReceive: Bool { enabled() && allowed() && model.ready && !model.busy && !model.confirmingClear }
    func enter(_ sender: NSDraggingInfo, notchFrame: NSRect? = nil) -> Bool {
        guard internalIDs.isEmpty else { return false }
        guard canReceive, !Self.urls(sender.draggingPasteboard).isEmpty else { return false }
        if let notchFrame {
            notchFeedback.locate(notchFrame)
            notchFeedback.reduced = reducesMotion()
            notchFeedback.hover()
        }
        if active { return sequence == sender.draggingSequenceNumber }
        active = true; hovering = true; sequence = sender.draggingSequenceNumber; committing = false
        notch = notchFrame ?? .zero
        priorKind = model.kind; priorDate = model.date; priorSelection = model.selection
        if notchFrame == nil { model.resetFilters() }
        onActivity(true)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkLocation() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        return true
    }
    private func checkLocation() {
        guard active, !committing else { return }
        let pointer = NSEvent.mouseLocation
        let outside = !notch.insetBy(dx: -3, dy: -3).contains(pointer) && !panelFrame().contains(pointer)
        if NSEvent.pressedMouseButtons == 0 || outside {
            let now = ProcessInfo.processInfo.systemUptime
            if let start = outsideSince, now - start > 0.18 { finish(cancelled: true) }
            else if outsideSince == nil { outsideSince = now }
        } else { outsideSince = nil }
    }
    @discardableResult
    func accept(_ sender: NSDraggingInfo, before target: UUID?, append: Bool = false, fromNotch: Bool) -> Bool {
        guard canReceive, !committing else { return false }
        let urls = Self.urls(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        if !active { guard enter(sender) else { return false } }
        guard sequence == sender.draggingSequenceNumber else { return false }
        if fromNotch {
            let accepted = notchFeedback.acceptOperation(sequence: sender.draggingSequenceNumber) { [self] in
                let accepted = await model.add(urls)
                finish(cancelled: false)
                if !accepted { throw NSError(domain: "JotBloom.FileShelf", code: 1) }
            }
            if accepted { committing = true; hovering = false }
            return accepted
        }
        committing = true; hovering = false
        Task {
            // A sentinel means append; nil inserts at the front.
            _ = await model.add(urls, before: append ? UUID() : target)
            finish(cancelled: false)
        }
        return true
    }
    func cancel() { if active && !committing { finish(cancelled: true) } }
    private func finish(cancelled: Bool) {
        timer?.invalidate(); timer = nil; outsideSince = nil
        active = false; hovering = false; sequence = nil; committing = false
        if cancelled { model.kind = priorKind; model.date = priorDate; model.selection = priorSelection }
        if cancelled { notchFeedback.leave() }
        onActivity(false)
        DispatchQueue.main.async { [weak self] in self?.onHotZoneRefresh() }
    }
    func startInternal(_ ids: Set<UUID>) { internalIDs = ids; internalDrop = false; onActivity(true) }
    func endInternal(_ operation: NSDragOperation) {
        let handoff = !internalDrop && !operation.isEmpty
        internalIDs = []; internalDrop = false; onActivity(false)
        if handoff { onExternalHandoff() }
    }
}
