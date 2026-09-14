import AppKit
import QuartzCore
import SwiftUI

/// Attach a lightweight, draggable indicator to the existing native scroll views.
/// The document view, wheel routing and saved reading position stay with NSScrollView.
struct BloomScrollbars: NSViewRepresentable {
    var reduceMotion: Bool
    func makeNSView(context: Context) -> Installer { Installer() }
    func updateNSView(_ view: Installer, context: Context) {
        view.reduceMotion = reduceMotion
        view.scheduleScan()
    }
    static func dismantleNSView(_ view: Installer, coordinator: ()) { view.stop() }

    final class Installer: NSView {
        var reduceMotion = false
        private var timer: Timer?
        private var pending = false
        private var indicators: [BloomScrollIndicator] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            guard window != nil else { return }
            scheduleScan()
            // SwiftUI can insert a nested scroll view without updating this representable.
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.scan() }
        }
        func scheduleScan() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in self?.pending = false; self?.scan() }
        }
        private func scan() {
            guard let window, window.isVisible, let content = window.contentView else { return }
            indicators.removeAll { indicator in
                if indicator.scroll?.window !== window { indicator.detach(); return true }
                indicator.reduceMotion = reduceMotion
                return false
            }
            func visit(_ view: NSView) {
                if let scroll = view as? NSScrollView {
                    if let existing = indicators.first(where: { $0.scroll === scroll }) {
                        existing.suppressNativeIndicator()
                    } else {
                        let indicator = BloomScrollIndicator(scroll: scroll)
                        indicator.reduceMotion = reduceMotion
                        indicators.append(indicator)
                    }
                }
                for child in view.subviews where !(child is BloomScrollIndicator) { visit(child) }
            }
            visit(content)
        }
        func stop() { timer?.invalidate(); timer = nil; indicators.forEach { $0.detach() }; indicators.removeAll() }
        deinit { timer?.invalidate() }
    }
}

final class BloomScrollIndicator: NSView {
    weak var scroll: NSScrollView?
    var reduceMotion = false {
        didSet { if reduceMotion { thumb.removeAllAnimations() } }
    }
    private let thumb = CALayer()
    private var observations: [NSObjectProtocol] = []
    private var hideTask: DispatchWorkItem?
    private var previousOrigin: NSPoint = .zero
    private var originalScroller = false
    private var thumbRect: NSRect = .zero
    private var dragging = false
    private var dragOffset: CGFloat = 0
    private(set) var shown = false
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThumbColor()
    }
    private func updateThumbColor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        thumb.backgroundColor = NSColor(calibratedWhite: dark ? 0.90 : 0.36, alpha: 1).cgColor
    }

    init(scroll: NSScrollView) {
        self.scroll = scroll
        self.originalScroller = scroll.hasVerticalScroller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        updateThumbColor()
        thumb.cornerRadius = 1.5
        thumb.opacity = 0
        thumb.transform = CATransform3DMakeTranslation(10, 0, 0)
        layer?.addSublayer(thumb)
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel("垂直滚动条")
        scroll.addSubview(self)
        suppressNativeIndicator()
        previousOrigin = scroll.contentView.bounds.origin
        scroll.contentView.postsBoundsChangedNotifications = true
        observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                guard let self, let scroll = self.scroll else { return }
                let moved = abs(scroll.contentView.bounds.origin.y - self.previousOrigin.y) > 0.1
                self.previousOrigin = scroll.contentView.bounds.origin
                self.updateGeometry()
                if moved { self.reveal() }
            })
        scroll.postsFrameChangedNotifications = true
        observations.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
            object: scroll, queue: .main) { [weak self] _ in self?.updateGeometry() })
        updateGeometry()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func suppressNativeIndicator() {
        guard let scroll else { return }
        if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
        updateGeometry()
    }
    private var range: CGFloat {
        guard let scroll else { return 0 }
        return max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
    }
    private var progress: CGFloat {
        guard let scroll, range > 0 else { return 0 }
        let raw = (scroll.contentView.bounds.minY - (scroll.documentView?.bounds.minY ?? 0)) / range
        return min(1, max(0, scroll.documentView?.isFlipped == false ? 1 - raw : raw))
    }
    func updateGeometry() {
        guard let scroll else { return }
        frame = NSRect(x: max(0, scroll.bounds.width - 14), y: 0, width: 14, height: scroll.bounds.height)
        let track = max(0, bounds.height - 8)
        let documentHeight = max(1, scroll.documentView?.bounds.height ?? 1)
        let length = min(track, max(28, track * scroll.contentView.bounds.height / documentHeight))
        thumbRect = NSRect(x: 8, y: 4 + progress * max(0, track - length), width: 3, height: length)
        CATransaction.begin(); CATransaction.setDisableActions(true); thumb.frame = thumbRect; CATransaction.commit()
        isHidden = range <= 1 || track < 28
        if isHidden { hideTask?.cancel(); setShown(false) }
        setAccessibilityValue(Int(progress * 100))
    }
    private func reveal() {
        guard !isHidden, window?.isVisible == true else { return }
        hideTask?.cancel()
        setShown(true)
        guard !dragging else { return }
        let task = DispatchWorkItem { [weak self] in self?.setShown(false) }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }
    private func setShown(_ value: Bool) {
        guard shown != value else { return }
        shown = value
        let old = thumb.presentation()
        let opacity = old?.opacity ?? thumb.opacity
        let translation = old?.transform.m41 ?? thumb.transform.m41
        thumb.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.opacity = value ? 0.52 : 0
        thumb.transform = CATransform3DMakeTranslation(value ? 0 : 10, 0, 0)
        CATransaction.commit()
        guard !reduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = opacity; fade.toValue = thumb.opacity
        let move = CABasicAnimation(keyPath: "transform.translation.x"); move.fromValue = translation; move.toValue = thumb.transform.m41
        let group = CAAnimationGroup(); group.animations = [fade, move]; group.duration = value ? 0.28 : 0.34
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        thumb.add(group, forKey: "visibility")
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shown, !isHidden else { return nil }
        let local = convert(point, from: superview)
        return NSRect(x: 0, y: thumbRect.minY - 5, width: 14, height: thumbRect.height + 10).contains(local) ? self : nil
    }
    override func scrollWheel(with event: NSEvent) { scroll?.scrollWheel(with: event) }
    override func mouseDown(with event: NSEvent) {
        dragging = true; hideTask?.cancel()
        dragOffset = convert(event.locationInWindow, from: nil).y - thumbRect.minY
    }
    override func mouseDragged(with event: NSEvent) {
        let travel = bounds.height - 8 - thumbRect.height
        guard travel > 0 else { return }
        let y = convert(event.locationInWindow, from: nil).y - dragOffset - 4
        scrollTo(min(1, max(0, y / travel)))
    }
    override func mouseUp(with event: NSEvent) { dragging = false; reveal() }
    private func scrollTo(_ fraction: CGFloat) {
        guard let scroll else { return }
        let actual = scroll.documentView?.isFlipped == false ? 1 - fraction : fraction
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
            y: (scroll.documentView?.bounds.minY ?? 0) + actual * range))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func accessibilityPerformIncrement() -> Bool { scrollTo(min(1, progress + 0.1)); return range > 0 }
    override func accessibilityPerformDecrement() -> Bool { scrollTo(max(0, progress - 0.1)); return range > 0 }
    func detach() {
        hideTask?.cancel(); observations.forEach { NotificationCenter.default.removeObserver($0) }; observations.removeAll()
        scroll?.hasVerticalScroller = originalScroller
        removeFromSuperview()
    }
    deinit { hideTask?.cancel(); observations.forEach { NotificationCenter.default.removeObserver($0) } }
#if DEBUG
    var debugThumbRect: NSRect { thumbRect }
    var debugSlide: CGFloat { thumb.presentation()?.transform.m41 ?? thumb.transform.m41 }
#endif
}
