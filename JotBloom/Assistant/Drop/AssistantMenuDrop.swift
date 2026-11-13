import AppKit
import JotBloomCore

/// The status item is the only persistent receiver. The two destinations exist
/// only during a native drag, and never activate the app or read the clipboard.
@MainActor
final class AssistantMenuDrop {
    let panel = AssistantMenuDropPanel()
    var allowed: () -> Bool = { false }
    var canStoreFiles: () -> Bool = { false }
    var storeText: (String) async throws -> Void = { _ in throw AssistantError.unavailable }
    var storeFiles: ([URL]) async -> Bool = { _ in false }
    var receive: ((String, [AssistantAttachment], String) -> Void)?
    var feedback: (Bool, String) -> Void = { _, _ in }
    private(set) var session = AssistantDropSession()
    private var grace: Task<Void, Never>?
    private var releaseMonitor: Any?
    private var writes: [UUID: Task<Void, Never>] = [:]
    var hasPendingWrites: Bool { !writes.isEmpty }
    init() { panel.destination.coordinator = self }

    static func text(_ board: NSPasteboard) -> String? {
        let types = board.types ?? []
        guard !types.contains(.fileURL), !types.contains(.init("NSFilenamesPboardType")),
              !types.contains(where: { $0.rawValue.lowercased().contains("filepromise") }) else { return nil }
        guard let value = board.string(forType: .string) ?? board.string(forType: .init("public.utf8-plain-text")),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private func valid(_ sender: NSDraggingInfo) -> Bool {
        allowed() && writes.count < 16 && sender.draggingSourceOperationMask.contains(.copy)
            && (!FileShelfDragController.urls(sender.draggingPasteboard).isEmpty || Self.text(sender.draggingPasteboard) != nil)
    }
    func enter(_ sender: NSDraggingInfo, anchor: NSView) -> Bool {
        guard valid(sender), let window = anchor.window, session.begin(sender.draggingSequenceNumber) else { return false }
        grace?.cancel()
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } ?? window.screen
        let frame = screen?.visibleFrame ?? rect.insetBy(dx: -300, dy: -300)
        let width: CGFloat = 248, height: CGFloat = 52
        panel.setFrame(NSRect(x: max(frame.minX + 6, min(rect.midX - width / 2, frame.maxX - width - 6)),
                              y: rect.minY - height - 6, width: width, height: height), display: true)
        panel.destination.hovered = nil
        panel.ignoresMouseEvents = false; panel.orderFrontRegardless()
        if releaseMonitor == nil {
            releaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in self?.leave() }
        }
        return true
    }
    func destination(_ sender: NSDraggingInfo) -> AssistantDropSession.Destination? {
        guard valid(sender), session.sequence == sender.draggingSequenceNumber else { return nil }
        let point = panel.destination.convert(sender.draggingLocation, from: nil)
        let bounds = panel.destination.bounds.insetBy(dx: 6, dy: 6)
        guard bounds.contains(point) else { return nil }
        if point.x < bounds.midX - 3 {
            guard FileShelfDragController.urls(sender.draggingPasteboard).isEmpty || canStoreFiles() else { return nil }
            return .notch // The existing session's storage destination.
        }
        return point.x > bounds.midX + 3 && receive != nil ? .assistant : nil
    }
    func hover(_ sender: NSDraggingInfo) -> Bool {
        let target = destination(sender)
        if valid(sender), session.sequence == sender.draggingSequenceNumber { grace?.cancel() }
        panel.destination.hovered = target
        return target != nil
    }
    func accept(_ sender: NSDraggingInfo) -> Bool {
        if session.destination(for: sender.draggingSequenceNumber) != nil { return true }
        guard let target = destination(sender) else { return false }
        let files = FileShelfDragController.urls(sender.draggingPasteboard)
        let text = files.isEmpty ? Self.text(sender.draggingPasteboard) ?? "" : ""
        guard session.commit(sender.draggingSequenceNumber, to: target) else { return false }
        finish()
        if target == .assistant { receive?(text, files.map(AssistantAttachment.file), UUID().uuidString); return true }
        let id = UUID()
        writes[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.writes[id] = nil }
            do {
                if files.isEmpty { try await self.storeText(text) }
                else if !(await self.storeFiles(files)) { throw AssistantError.unavailable }
                self.feedback(true, files.isEmpty ? "已存入灵感" : "已存入中转站")
            } catch { self.feedback(false, "未能全部保存，原内容未修改，请重试") }
        }
        return true
    }
    func leave() {
        grace?.cancel()
        grace = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 220_000_000) } catch { return }
            self?.cancel()
        }
    }
    func cancel() { session.cancel(); finish() }
    private func finish() {
        grace?.cancel(); grace = nil
        if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor); self.releaseMonitor = nil }
        panel.destination.hovered = nil; panel.ignoresMouseEvents = true; panel.orderOut(nil)
    }
    func drain() async { cancel(); for work in Array(writes.values) { await work.value } }
    func stop() { cancel(); panel.close() }
}

@MainActor
final class AssistantMenuDropPanel: NSPanel {
    let destination = AssistantMenuDestination(frame: .zero)
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true; hidesOnDeactivate = false
        isReleasedWhenClosed = false; animationBehavior = .none
        level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        title = "存入或交给助手"; contentView = destination
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AssistantMenuDestination: NSView {
    weak var coordinator: AssistantMenuDrop?
    var hovered: AssistantDropSession.Destination? { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame); registerForDraggedTypes([.fileURL, .string, .init("public.utf8-plain-text")])
        setAccessibilityLabel("左侧存入，右侧交给助手；移出取消。也可用快捷键打开助手后拖入。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 26, yRadius: 26)
        NSColor.black.setFill(); shape.fill(); NSColor.white.withAlphaComponent(0.12).setStroke(); shape.lineWidth = 0.5; shape.stroke()
        let left = NSRect(x: 6, y: 6, width: bounds.width / 2 - 9, height: bounds.height - 12)
        let right = left.offsetBy(dx: bounds.width / 2 + 3, dy: 0)
        for (rect, target, title) in [(left, AssistantDropSession.Destination.notch, "存入"), (right, .assistant, "交给助手")] {
            if hovered == target { NSColor.white.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20).fill() }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { coordinator?.hover(sender) == true ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil; coordinator?.leave() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { coordinator?.destination(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { coordinator?.accept(sender) == true }
    override func draggingEnded(_ sender: NSDraggingInfo) { coordinator?.leave() }
}

@MainActor
final class AssistantStatusDropView: NSView {
    weak var coordinator: AssistantMenuDrop?
    weak var button: NSStatusBarButton?
    var pending = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame); registerForDraggedTypes([.fileURL, .string, .init("public.utf8-plain-text")])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if pending {
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 7, y: bounds.maxY - 7, width: 5, height: 5)).fill()
        }
    }
    override func mouseDown(with event: NSEvent) { button?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { button?.rightMouseDown(with: event) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        coordinator?.enter(sender, anchor: self) == true ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { coordinator?.leave() }
    override func draggingEnded(_ sender: NSDraggingInfo) { coordinator?.leave() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { coordinator?.cancel(); return false }
}
