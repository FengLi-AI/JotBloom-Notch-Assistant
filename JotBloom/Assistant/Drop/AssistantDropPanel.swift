import AppKit
import SwiftUI

@MainActor
final class AssistantDropAppearance: ObservableObject {
    @Published var visible = false
    @Published var hovering = false
    var reduced = false
}

private struct AssistantDropBubble: View {
    @ObservedObject var model: AssistantDropAppearance
    var body: some View {
        HStack(spacing: 8) {
            BloomSymbol("checklist", size: 15)
            Text("交给助手").font(BloomTypography.font(12, role: .label))
        }.foregroundStyle(.white).frame(width: 148, height: 36)
            .background(.black, in: Capsule())
            .overlay(Capsule().fill(.white.opacity(model.hovering ? 0.12 : 0)).allowsHitTesting(false))
            .scaleEffect(model.visible ? (model.hovering && !model.reduced ? 1.08 : 1) : (model.reduced ? 1 : 0.45))
            .offset(y: model.visible || model.reduced ? 0 : -20)
            .opacity(model.visible ? 1 : 0)
            .animation(model.reduced ? .easeOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.78), value: model.visible)
            .animation(model.reduced ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: model.hovering)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class AssistantDropPanel: NSPanel {
    let destination = AssistantDropView(frame: .zero)
    let bubbleAppearance = AssistantDropAppearance()
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; isReleasedWhenClosed = false; animationBehavior = .none
        level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        title = "交给助手"; contentView = destination
        let host = NSHostingView(rootView: AssistantDropBubble(model: bubbleAppearance))
        host.frame = destination.bounds; host.autoresizingMask = [.width, .height]
        destination.addSubview(host)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    func locate(notch: CGRect) {
        // The existing visible hint extends 16 pt below a 32 pt notch.
        // Keep an 8 pt visual gap, with 12 pt of destination padding.
        setFrame(CGRect(x: notch.midX - 86, y: notch.minY - 16 * notch.height / 32 - 8 - 48,
                        width: 172, height: 60), display: true)
    }
}

@MainActor
final class AssistantDropView: NSView {
    weak var coordinator: AssistantDropCoordinator?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string, .init("public.utf8-plain-text")])
        setAccessibilityLabel("交给助手，松手创建任务")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { coordinator?.enterBubble(sender) == true ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { coordinator?.leave() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { coordinator?.canAccept(sender) == true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { coordinator?.accept(sender) == true }
    override func draggingEnded(_ sender: NSDraggingInfo) { coordinator?.end(sequence: sender.draggingSequenceNumber) }
}
