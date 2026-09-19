import AppKit
import JotBloomCore

@MainActor
final class CompanionOverlay: NSPanel {
    let stage = CompanionStageView(frame: .zero)
    private(set) var notch: CGRect = .zero

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; isFloatingPanel = true
        animationBehavior = .none
        title = "萌生小伙伴"
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = stage
        ignoresMouseEvents = true
        setAccessibilityLabel("萌生小伙伴")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @discardableResult
    func locate() -> Bool {
        for screen in NSScreen.screens {
            let metrics = ScreenLocator.metrics(for: screen)
            guard let physical = PanelGeometry.physicalNotchFrame(for: metrics) else { continue }
            notch = physical
            let scale = physical.height / 32
            setFrame(CGRect(x: physical.minX - 45 * scale, y: physical.minY,
                            width: 45 * scale, height: physical.height), display: true)
            return true
        }
        orderOut(nil)
        return false
    }

    func update(_ frame: CompanionFrame) {
        stage.frameState = frame
        if frame.number("width") < 0.01 || frame.text("phase") == "hidden" {
            orderOut(nil); ignoresMouseEvents = true
        } else {
            if !isVisible { orderFrontRegardless() }
            stage.needsDisplay = true
            updateHitRegion()
        }
    }

    func updateHitRegion() {
        let point = convertPoint(fromScreen: NSEvent.mouseLocation)
        ignoresMouseEvents = !stage.containsVisiblePixel(stage.convert(point, from: nil))
    }
}

@MainActor
final class CompanionStageView: NSView {
    var onClick: (() -> Void)?
    var frameState: CompanionFrame? {
        didSet {
            if let frameState, frameState.number("opacity") > 0 {
                sprite = CompanionRasterizer.render(frameState.commands)
            } else { sprite = nil }
        }
    }
    private var sprite: CGImage?
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var spriteRect: CGRect {
        guard let frameState else { return .zero }
        return CGRect(x: 45 + frameState.number("x") - 665.5, y: 0, width: 40, height: 32)
    }

    private var pocket: CGPath {
        let path = CGMutablePath()
        guard let state = frameState, state.flag("backdrop"), state.number("width") > 0.01 else { return path }
        let l = 45 - state.number("width"), r: CGFloat = 64.5
        path.move(to: CGPoint(x: r, y: 0)); path.addLine(to: CGPoint(x: r, y: 32))
        path.addLine(to: CGPoint(x: l + 13, y: 32))
        path.addCurve(to: CGPoint(x: l + 4, y: 23), control1: CGPoint(x: l + 8.02944, y: 32), control2: CGPoint(x: l + 4, y: 27.9706))
        path.addLine(to: CGPoint(x: l + 4, y: 4))
        path.addCurve(to: CGPoint(x: l, y: 0), control1: CGPoint(x: l + 4, y: 1.79086), control2: CGPoint(x: l + 2.20914, y: 0))
        path.closeSubpath()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext, let state = frameState else { return }
        c.clear(bounds)
        c.saveGState(); defer { c.restoreGState() }
        c.scaleBy(x: bounds.width / 45, y: bounds.height / 32)
        if state.flag("backdrop") {
            c.setFillColor(CGColor(gray: 0, alpha: 1)); c.addPath(pocket); c.fillPath()
        }
        // The overlay ends exactly at the physical notch edge. Never intercept it.
        c.clip(to: CGRect(x: 45 - state.number("width"), y: 0, width: state.number("width"), height: 32))
        guard let sprite else { return }
        c.setAlpha(state.number("opacity")); c.interpolationQuality = .none
        let rect = spriteRect
        c.translateBy(x: rect.minX, y: rect.maxY); c.scaleBy(x: 1, y: -1)
        c.draw(sprite, in: CGRect(origin: .zero, size: rect.size))
    }

    func containsVisiblePixel(_ point: CGPoint) -> Bool {
        guard bounds.width > 0, bounds.height > 0, let state = frameState,
              state.number("width") > 0.01 else { return false }
        let p = CGPoint(x: point.x / bounds.width * 45, y: point.y / bounds.height * 32)
        guard CGRect(x: 45 - state.number("width"), y: 0, width: state.number("width"), height: 32).contains(p) else { return false }
        if state.flag("backdrop") { return pocket.contains(p) }
        guard state.number("opacity") > 0.1, spriteRect.contains(p), let sprite,
              let data = sprite.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let x = min(79, max(0, Int((p.x - spriteRect.minX) * 2)))
        let y = min(63, max(0, Int(p.y * 2)))
        return bytes[y * sprite.bytesPerRow + x * 4 + 3] > 24
    }

    override func mouseDown(with event: NSEvent) {
        if containsVisiblePixel(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        frameState?.flag("resident") == true ? "萌生小伙伴，点击互动" : "萌生小伙伴，点击收起"
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
