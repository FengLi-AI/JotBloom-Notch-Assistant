import AppKit

enum NotchFeedbackPhase { case idle, hover, ack, absorb, glow, flash, cancel, failure }

@MainActor
final class NotchFeedbackPanel: NSPanel {
    let stage = NotchFeedbackView(frame: .zero)
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; ignoresMouseEvents = true; isReleasedWhenClosed = false
        animationBehavior = .none; title = "萌生收录反馈"
        level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = stage
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    func locate(_ notch: CGRect) {
        guard notch.height > 0 else { orderOut(nil); return }
        let s = notch.height / 32
        stage.logicalWidth = notch.width / s
        setFrame(CGRect(x: notch.minX - 8 * s, y: notch.minY - 26 * s,
                        width: notch.width + 16 * s, height: notch.height + 26 * s), display: true)
    }
}

@MainActor
final class NotchFeedbackView: NSView {
    var phase: NotchFeedbackPhase = .idle
    var elapsed = 0.0
    var expansion = 0.0
    var reduced = false
    var label = ""
    var logicalWidth: CGFloat = 179
    override var isFlipped: Bool { true }
    private func eased(_ value: Double) -> CGFloat {
        let t = min(1, max(0, value)); return CGFloat(t * t * (3 - 2 * t))
    }
    private func progress(_ u: Double, _ start: Double, _ end: Double) -> CGFloat { eased((u - start) / (end - start)) }

    func liquid(height: CGFloat, width: CGFloat, wave: CGFloat = 0) -> CGPath {
        let n = logicalWidth, top: CGFloat = 22, bottom = 32 + height
        let left: CGFloat = 3, right = n - 3, l = (n - width) / 2, r = (n + width) / 2
        let corner = max(0, min(9, width * 0.24, (bottom - top) * 0.9)), k = corner * 0.55228475
        let shoulder = bottom - corner, p = CGMutablePath()
        p.move(to: CGPoint(x: left, y: top)); p.addLine(to: CGPoint(x: right, y: top))
        p.addCurve(to: CGPoint(x: r, y: shoulder), control1: CGPoint(x: right, y: top + (shoulder - top) * 0.65), control2: CGPoint(x: r, y: shoulder))
        p.addCurve(to: CGPoint(x: r - corner, y: bottom), control1: CGPoint(x: r, y: shoulder + k), control2: CGPoint(x: r - corner + k, y: bottom + wave * 0.2))
        p.addCurve(to: CGPoint(x: l + corner, y: bottom), control1: CGPoint(x: n / 2 + width * 0.18, y: bottom + wave), control2: CGPoint(x: n / 2 - width * 0.18, y: bottom - wave * 0.6))
        p.addCurve(to: CGPoint(x: l, y: shoulder), control1: CGPoint(x: l + corner - k, y: bottom - wave * 0.2), control2: CGPoint(x: l, y: shoulder + k))
        p.addCurve(to: CGPoint(x: left, y: top), control1: CGPoint(x: l, y: shoulder), control2: CGPoint(x: left, y: top + (shoulder - top) * 0.65))
        p.closeSubpath(); return p
    }

    /// The route is intentionally open. There is no top stroke across the camera.
    var rim: CGPath {
        let n = logicalWidth, p = CGMutablePath()
        p.move(to: CGPoint(x: -3.75, y: 0))
        p.addCurve(to: CGPoint(x: -0.75, y: 3), control1: CGPoint(x: -2.09315, y: 0), control2: CGPoint(x: -0.75, y: 1.34315))
        p.addLine(to: CGPoint(x: -0.75, y: 23))
        p.addCurve(to: CGPoint(x: 9, y: 32.75), control1: CGPoint(x: -0.75, y: 28.3858), control2: CGPoint(x: 3.6142, y: 32.75))
        p.addLine(to: CGPoint(x: n - 9, y: 32.75))
        p.addCurve(to: CGPoint(x: n + 0.75, y: 23), control1: CGPoint(x: n - 3.6142, y: 32.75), control2: CGPoint(x: n + 0.75, y: 28.3858))
        p.addLine(to: CGPoint(x: n + 0.75, y: 3))
        p.addCurve(to: CGPoint(x: n + 3.75, y: 0), control1: CGPoint(x: n + 0.75, y: 1.34315), control2: CGPoint(x: n + 2.09315, y: 0))
        return p
    }
    override func draw(_ dirtyRect: NSRect) {
        guard phase != .idle, let c = NSGraphicsContext.current?.cgContext else { return }
        c.saveGState(); defer { c.restoreGState() }
        let scale = bounds.height / 58
        c.scaleBy(x: scale, y: scale); c.translateBy(x: 8, y: 0)
        var h = 16 * CGFloat(expansion), w = logicalWidth - 6, wave: CGFloat = 0
        var alpha = min(1, max(0, CGFloat(expansion) * 4)), textAlpha = eased((expansion - 0.5) / 0.45)
        if phase == .ack { wave = reduced ? 0 : CGFloat(sin(elapsed * 24) * exp(-elapsed * 8) * 0.85); textAlpha = 1 }
        if phase == .hover { wave = reduced ? 0 : CGFloat(sin(elapsed * 2.9) * 0.12) }
        if phase == .absorb {
            let u = elapsed / (reduced ? 0.18 : 0.82)
            w += (8 - w) * progress(u, 0, 0.7); h = 16 - 26 * progress(u, 0.26, 1)
            alpha = 1 - progress(u, 0.87, 1); textAlpha = 1 - progress(u, 0, 0.35)
        }
        if phase == .cancel { alpha *= 1 - eased(elapsed / 0.24); textAlpha = 0 }
        if phase == .glow || phase == .flash { alpha = 0; textAlpha = 0; drawRim(c); return }
        c.saveGState(); c.setAlpha(alpha); c.setFillColor(NSColor.black.cgColor)
        c.addPath(liquid(height: h, width: w, wave: wave)); c.fillPath(); c.restoreGState()
        if phase == .ack && !reduced {
            for i in 0...1 {
                let age = elapsed - Double(i) * 0.13, v = min(1, max(0, age / 0.68))
                guard age >= 0 && v < 1 else { continue }
                c.saveGState(); c.setAlpha(CGFloat((1 - v) * 0.15))
                c.translateBy(x: logicalWidth / 2, y: 32); c.scaleBy(x: 1 + v * 0.025, y: 1 + v * 0.1); c.translateBy(x: -logicalWidth / 2, y: -32)
                c.setStrokeColor(NSColor.white.cgColor); c.setLineWidth(0.4 - v * 0.2)
                c.addPath(liquid(height: 16, width: logicalWidth - 6)); c.strokePath(); c.restoreGState()
            }
        }
        if textAlpha > 0 {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(white: 0.91, alpha: textAlpha)]
            let text = label as NSString, size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (logicalWidth - size.width) / 2, y: 32 + h - 14), withAttributes: attributes)
        }
    }
    private func drawRim(_ c: CGContext) {
        let u = elapsed / (phase == .glow ? (reduced ? 0.28 : 0.92) : (reduced ? 0.04 : 0.32))
        var opacity: CGFloat = reduced ? 0.25 : progress(u, 0, 0.07)
        if phase == .flash { opacity = reduced ? 0 : u < 0.32 ? 1 - eased(u / 0.32) : u < 0.59 ? 0.92 * eased((u - 0.32) / 0.27) : 0.92 * (1 - eased((u - 0.59) / 0.41)) }
        let colors = ["AFF0FF", "1A58DE", "DCA3FF", "9338EE", "70BAFF"].map { hex -> CGColor in
            let n = UInt32(hex, radix: 16)!
            return CGColor(red: CGFloat(n >> 16 & 255) / 255, green: CGFloat(n >> 8 & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
        }
        c.saveGState(); c.setAlpha(opacity * 0.3); c.setLineWidth(2)
        c.setShadow(offset: .zero, blur: 3, color: colors[2]); c.setStrokeColor(colors[2]); c.addPath(rim); c.strokePath(); c.restoreGState()
        c.saveGState(); c.setAlpha(opacity); c.addPath(rim); c.setLineWidth(1.1); c.replacePathWithStrokedPath(); c.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.216314, 0.490385, 0.74903, 1])!
        c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 16), end: CGPoint(x: logicalWidth, y: 16), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]); c.restoreGState()
        guard phase == .glow, !reduced else { return }
        // A dashed bright head advances along the open contour twice.
        let length = logicalWidth + 2 * 23 + 2 * 9.75 * .pi / 2 + 6
        c.saveGState(); c.setAlpha(opacity * 0.95); c.setStrokeColor(CGColor(red: 0.85, green: 0.97, blue: 1, alpha: 1))
        c.setLineWidth(1.45); c.setLineCap(.round)
        c.setLineDash(phase: length - CGFloat(u * 2).truncatingRemainder(dividingBy: 1) * length, lengths: [length * 0.13, length * 0.87])
        c.addPath(rim); c.strokePath(); c.restoreGState()
    }
}
