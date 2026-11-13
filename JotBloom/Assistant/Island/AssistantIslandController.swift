import AppKit
import SwiftUI
import JotBloomCore

@MainActor
final class AssistantIslandController {
    let panel = AssistantIslandPanel()
    let model = IslandViewModel()
    let gate = PresentationGate()
    private(set) var queue = IslandEventQueue()
    var onAction: ((IslandAction, [IslandContent]) -> Bool)?
    var onPresent: ((IslandContent) -> Void)?
    var onPendingChanged: ((Bool) -> Void)?
    var onStateChanged: (() -> Void)?
    var companionWindowNumber: (() -> Int?)?
    var appReducesMotion: () -> Bool = { false }
    var forcedFloating = false
#if DEBUG && JOTBLOOM_LOCAL_DEVELOPMENT
    // The device simulator renders this same model inside its own mock desktop.
    // It never places an overlay over the real camera or claims native ActivityKit support.
    var previewDisplay: IslandPreviewDisplay?
    func previewHover(_ inside: Bool) { hoverChanged(inside) }
#endif
    var speedMultiplier: Double = 1
    var quiet = false { didSet { reconcileEnvironment() } }
    var needsIndicator: Bool { queue.hasPending || (quiet && !queue.waiting.isEmpty) }
    private var compactGeometry = IslandGeometry(width: 280, height: 72, bottomRadius: 20, shoulderRadius: 15)
    private var baseGeometry = IslandGeometry(width: 180, height: 32, bottomRadius: 10, shoulderRadius: 4)
    private var timers: [String: Task<Void, Never>] = [:]
    private var monitors: [Any] = []
    private var hovered = false
    private var suppressed = false
    private var stopped = false
    private var floatingOffset: CGFloat = 6
    private var measuredCard: (content: IslandContent, topInset: CGFloat, height: CGFloat)?

    private var disappearsWhenClosed: Bool {
#if DEBUG && JOTBLOOM_LOCAL_DEVELOPMENT
        if previewDisplay == .camera { return false }
#endif
        return model.floating
    }

    init() {
        model.hitRegion.panel = panel
        panel.contentView = IslandHostingView(rootView: AssistantIslandView(model: model))
        model.onExpand = { [weak self] in self?.expand() }
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onAction = { [weak self] action in self?.perform(action) }
        model.hitRegion.onHover = { [weak self] in self?.hoverChanged($0) }
        gate.onChange = { [weak self] in self?.reconcileEnvironment() }
    }

    func start() {
        locate(); model.geometry = baseGeometry
        gate.start()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                          .leftMouseDown, .rightMouseDown, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.observeMouse(event)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.observeMouse(event); return event
        }) { monitors.append(monitor) }
    }

    func stop() {
        stopped = true; cancelTimers(); gate.stop()
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        model.hitRegion.enabled = false; model.hitRegion.update()
        panel.orderOut(nil); panel.contentView = nil; panel.close()
    }

    func receive(_ content: IslandContent) {
        guard !stopped else { return }
        gate.refresh()
        let before = queue.current
        let allowed = gate.allowsPresentation && !quiet
        queue.enqueue(content, at: ProcessInfo.processInfo.systemUptime, presenting: allowed)
        onPendingChanged?(needsIndicator)
        if allowed, before != queue.current { showCurrent() }
        else if quiet, gate.allowsPresentation { rest() }
        onStateChanged?()
    }

    func expand() {
        guard model.stage == .compact, queue.current != nil else { return }
        cancel("dismiss")
        transition(to: .expanded, animation: IslandMotion.openExpanded)
    }

    func collapse() {
        guard model.stage == .expanded else { return }
        transition(to: .compact, animation: IslandMotion.closeExpanded)
        scheduleDismiss(seconds: 3)
    }

    func dismiss(resolved: Bool = false) {
        guard model.stage == .compact || model.stage == .expanded else { return }
        queue.dismissCurrent(resolved: resolved)
        onPendingChanged?(needsIndicator)
        closeSurface { [weak self] in
            guard let self else { return }
            self.queue.advance()
            if self.queue.current != nil, self.gate.allowsPresentation, !self.quiet { self.showCurrent() }
            else { self.rest() }
        }
    }

    func resolve(_ ids: Set<UUID>) {
        let before = queue.current
        queue.resolve(ids); onPendingChanged?(needsIndicator)
        if model.stage == .glow { rest() }
        else if before != queue.current, model.stage == .compact || model.stage == .expanded {
            if queue.current != nil { showCurrent() }
            else { dismiss() }
        }
    }

    func setRunning(_ running: Bool) {
        model.running = running
        if model.stage == .hidden { rest() }
    }

    /// A fresh fake scenario, used only by the DEBUG preview host.
    func reset() {
        cancelTimers(); queue = IslandEventQueue(); hovered = false
        model.contentVisible = false; model.content = nil; model.stage = .hidden
        model.surfaceVisible = false; model.glowOpacity = 0; model.running = false
        model.surfaceOpacity = 0
        model.hitRegion.enabled = false; model.hitRegion.update(); panel.orderOut(nil)
        onPendingChanged?(false); onStateChanged?()
    }

    func refreshAppearance() {
        let previousReduction = model.reduced, previousFloating = model.floating, previousFrame = panel.frame
        model.reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || appReducesMotion()
        // Re-anchoring is an environment change, not an animated window resize.
        locate()
#if DEBUG && JOTBLOOM_LOCAL_DEVELOPMENT
        if previewDisplay != nil, model.stage == .hidden { model.geometry = baseGeometry }
#endif
        guard previousReduction != model.reduced || previousFloating != model.floating || previousFrame != panel.frame else { return }
        model.offsetY = model.floating && (model.stage == .compact || model.stage == .expanded) ? floatingOffset : 0
        if model.stage == .compact || model.stage == .expanded {
            model.geometry = geometry(for: model.stage)
            model.hitRegion.present(model.geometry)
        }
        if model.stage == .glow { glow() }
    }

    private func showCurrent() {
        guard let content = queue.current?.content else { return }
        cancel("close"); cancel("finishClose"); cancel("glow")
        model.reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || appReducesMotion()
        let alreadyVisible = model.stage == .compact || model.stage == .expanded
        if !alreadyVisible {
            locate(); model.geometry = baseGeometry; model.offsetY = 0
            model.surfaceVisible = !model.reduced
            model.surfaceOpacity = disappearsWhenClosed ? 0 : 1
            showWindow()
        }
        let width = (content.compactLabel as NSString).size(withAttributes: [.font: BloomTypography.nsFont(12, role: .label)]).width + 65
        compactGeometry.width = min(360, max(280, width))
#if DEBUG && JOTBLOOM_LOCAL_DEVELOPMENT
        if previewDisplay == .camera { compactGeometry.width = 360 }
#endif
        let target: IslandStage = alreadyVisible && model.stage == .expanded ? .expanded : .compact
        transition(to: target, animation: alreadyVisible ? IslandMotion.contentSwap : IslandMotion.openCompact)
        scheduleDismiss(seconds: content.policy.seconds)
        onPresent?(content)
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: content.compactText, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func transition(to stage: IslandStage, animation: Animation) {
        cancel("content"); cancel("close"); cancel("finishClose")
        if model.reduced { model.offsetY = model.floating ? floatingOffset : 0 }
        withAnimation(motion(IslandMotion.contentOut)) { model.contentVisible = false }
        withAnimation(motion(animation)) {
            model.stage = stage; model.surfaceVisible = true
            model.surfaceOpacity = 1
            model.geometry = geometry(for: stage)
            if !model.reduced { model.offsetY = model.floating ? floatingOffset : 0 }
        }
        model.hitRegion.offsetY = model.floating ? floatingOffset : 0
        model.hitRegion.enabled = true; model.hitRegion.update()
        after("content", seconds: model.reduced ? 0 : IslandMotion.contentInDelay) { [weak self] in
            guard let self else { return }
            self.model.content = self.queue.current?.content
            self.model.contentStage = stage
            self.model.contentVersion = UUID()
            withAnimation(self.motion(IslandMotion.contentIn)) { self.model.contentVisible = true }
        }
        onStateChanged?()
    }

    private func closeSurface(completion: @escaping () -> Void) {
        cancel("dismiss"); cancel("content"); cancel("glow")
        model.hitRegion.enabled = false; model.hitRegion.update()
        withAnimation(motion(IslandMotion.contentOut)) { model.contentVisible = false }
        let floatingExit = disappearsWhenClosed
        after("close", seconds: model.reduced ? 0 : IslandMotion.shapeCloseDelay) { [weak self] in
            guard let self else { return }
            withAnimation(self.motion(floatingExit ? IslandMotion.floatingClose : IslandMotion.closeCompact)) {
                // A floating island has no hardware to return to. Keep it pill-shaped
                // while shrinking and fading in one motion, instead of parking on a circle.
                if floatingExit, !self.model.reduced {
                    self.model.geometry = .init(width: 80, height: 12, bottomRadius: 6, shoulderRadius: 0)
                } else if !self.model.reduced {
                    self.model.geometry = self.baseGeometry
                }
                if !self.model.reduced { self.model.offsetY = 0 }
                if floatingExit || self.model.reduced { self.model.surfaceOpacity = 0 }
                if self.model.reduced { self.model.surfaceVisible = false }
            }
        }
        let finishDelay = model.reduced ? 0.18 : floatingExit
            ? IslandMotion.shapeCloseDelay + IslandMotion.floatingCloseDuration + 0.02 : IslandMotion.settleTime
        after("finishClose", seconds: finishDelay) { [weak self] in
            guard let self else { return }
            self.model.stage = .hidden; self.model.surfaceVisible = false; self.model.content = nil
            completion()
        }
    }

    private func rest() {
        guard gate.allowsPresentation else { panel.orderOut(nil); return }
        locate()
        model.geometry = baseGeometry; model.offsetY = 0
        model.surfaceVisible = false; model.contentVisible = false
        model.surfaceOpacity = disappearsWhenClosed || model.reduced ? 0 : 1
        model.hitRegion.enabled = false; model.hitRegion.update()
        model.stage = needsIndicator ? .glow : .hidden
        if needsIndicator && !model.floating { showWindow(); glow() }
        else if model.running && !model.floating { showWindow() }
        else { panel.orderOut(nil) }
        onStateChanged?()
    }

    private func glow() {
        cancel("glow")
        model.glowOpacity = model.reduced ? 0.25 : 0
        guard !model.reduced else { return }
        withAnimation(IslandMotion.glowIn.speed(1 / speedMultiplier)) { model.glowOpacity = 0.7 }
        timers["glow"] = Task { @MainActor [weak self] in
            guard let self else { return }
            for opacity in [0.25, 0.7, 0.25, 0.7, 0.25] {
                do { try await Task.sleep(nanoseconds: UInt64(0.7 * self.speedMultiplier * 1e9)) }
                catch { return }
                guard self.model.stage == .glow else { return }
                withAnimation(IslandMotion.glowBreath.speed(1 / self.speedMultiplier)) { self.model.glowOpacity = opacity }
            }
            self.timers["glow"] = nil
        }
    }

    private func geometry(for stage: IslandStage) -> IslandGeometry {
        if stage == .compact {
            var result = compactGeometry
            if hovered && !model.reduced { result.width *= 1.02; result.height *= 1.02 }
            return result
        }
        if stage == .expanded {
            guard let content = queue.current?.content else { return baseGeometry }
            var topInset: CGFloat = 0
#if DEBUG && JOTBLOOM_LOCAL_DEVELOPMENT
            if previewDisplay == .camera { topInset = IslandLayout.cameraClearance }
#endif
            if measuredCard?.content != content || measuredCard?.topInset != topInset {
                let card = IslandExpandedCard(content: content, topInset: topInset, onAction: { _ in })
                let host = NSHostingView(rootView: card)
                measuredCard = (content, topInset, host.fittingSize.height)
            }
            return IslandGeometry(width: IslandLayout.cardWidth,
                                  height: model.notchSize.height + (measuredCard?.height ?? 0),
                                  bottomRadius: model.floating ? IslandLayout.floatingCardRadius : IslandLayout.attachedCardRadius,
                                  shoulderRadius: model.floating ? 0 : 15)
        }
        return baseGeometry
    }

    private func locate() {
#if DEBUG && JOTBLOOM_LOCAL_DEVELOPMENT
        if let display = previewDisplay {
            model.floating = display != .notch
            model.notchSize = display == .notch ? CGSize(width: 180, height: 32) : .zero
            floatingOffset = display == .camera ? 0 : 6
            baseGeometry = IslandGeometry(width: display == .notch ? 180 : display == .camera ? 104 : 40,
                                          height: display == .notch ? 32 : display == .camera ? 24 : 40,
                                          bottomRadius: display == .notch ? 10 : display == .camera ? 12 : 20,
                                          shoulderRadius: display == .notch ? 4 : 0)
            compactGeometry.height = model.notchSize.height + 40
            compactGeometry.shoulderRadius = display == .notch ? 15 : 0
            model.hitRegion.notch = nil
            model.hitRegion.offsetY = floatingOffset
            return
        }
#endif
        floatingOffset = 6
        guard let screen = ScreenLocator.screenUnderMouse() else { return }
        let metrics = ScreenLocator.metrics(for: screen)
        let notch = forcedFloating ? nil : PanelGeometry.physicalNotchFrame(for: metrics)
        model.floating = notch == nil
        model.notchSize = notch?.size ?? .zero
        // Fixed maximum canvas leaves room for the L3 spring overshoot. Never animated.
        let canvas = CGSize(width: 520, height: (notch?.height ?? 0) + 270)
        let top = notch?.maxY ?? (screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness))
        let next = CGRect(x: (notch?.midX ?? screen.frame.midX) - canvas.width / 2, y: top - canvas.height,
                          width: canvas.width, height: canvas.height)
        if panel.frame != next { panel.setFrame(next, display: true) }
        baseGeometry = IslandGeometry(width: notch?.width ?? 40, height: notch?.height ?? 40,
                                      bottomRadius: notch == nil ? 20 : 10, shoulderRadius: notch == nil ? 0 : 4)
        compactGeometry.height = (notch?.height ?? 0) + 40
        compactGeometry.shoulderRadius = notch == nil ? 0 : 15
        model.hitRegion.notch = notch.map { CGRect(x: $0.minX - next.minX, y: 0, width: $0.width, height: $0.height) }
        model.hitRegion.offsetY = model.floating ? 6 : 0
    }

    private func showWindow() {
#if DEBUG && JOTBLOOM_LOCAL_DEVELOPMENT
        if previewDisplay != nil { panel.orderOut(nil); return }
#endif
        if let number = companionWindowNumber?() { panel.order(.below, relativeTo: number) }
        else { panel.orderFrontRegardless() }
    }

    private func reconcileEnvironment() {
        guard !stopped else { return }
        defer { onPendingChanged?(needsIndicator) }
        if !gate.allowsPresentation || quiet {
            if !suppressed {
                queue.suspend(); suppressed = true; cancelTimers()
                model.contentVisible = false; model.surfaceVisible = false; model.stage = .hidden
                model.surfaceOpacity = 0
                model.hitRegion.enabled = false; model.hitRegion.update(); panel.orderOut(nil)
            }
            if quiet && gate.allowsPresentation { rest() }
        } else if suppressed {
            suppressed = false; queue.resume()
            if queue.current != nil { showCurrent() } else { rest() }
        } else if panel.isVisible {
            refreshAppearance()
        }
        onStateChanged?()
    }

    private func hoverChanged(_ value: Bool) {
        hovered = value
        guard queue.current != nil, model.stage == .compact || model.stage == .expanded else { return }
        if model.stage == .compact {
            withAnimation(motion(IslandMotion.hover)) { model.geometry = geometry(for: .compact) }
        }
        if value { cancel("dismiss") }
        else { scheduleDismiss(seconds: 3) }
    }

    private func scheduleDismiss(seconds: Double) {
        cancel("dismiss")
        guard !hovered, model.stage == .compact else { return }
        after("dismiss", seconds: seconds, scaled: false) { [weak self] in self?.dismiss() }
    }

    private func observeMouse(_ event: NSEvent) {
        guard panel.isVisible else { return }
        model.hitRegion.update()
        if (event.type == .leftMouseDown || event.type == .rightMouseDown),
           model.stage == .expanded, !model.hitRegion.contains(NSEvent.mouseLocation) { dismiss() }
        if event.type == .scrollWheel, model.hitRegion.contains(NSEvent.mouseLocation), event.scrollingDeltaY > 12 {
            dismiss()
        }
    }

    private func perform(_ action: IslandAction) {
        guard let batch = queue.current else { return }
        // Detach the visible event before the host opens the main panel. The gate
        // can suspend synchronously there; an already-opened event must not replay.
        queue.dismissCurrent()
        let resolved = onAction?(action, batch.events) ?? false
        if resolved { queue.resolve(Set(batch.events.map(\.id))) }
        onPendingChanged?(queue.hasPending)
        dismiss()
    }

    private func motion(_ animation: Animation) -> Animation {
        (model.reduced ? IslandMotion.reduced : animation).speed(1 / speedMultiplier)
    }
    private func cancel(_ name: String) { timers.removeValue(forKey: name)?.cancel() }
    private func cancelTimers() { timers.values.forEach { $0.cancel() }; timers.removeAll() }
    private func after(_ name: String, seconds: Double, scaled: Bool = true, action: @escaping () -> Void) {
        cancel(name)
        let delay = seconds * (scaled ? speedMultiplier : 1)
        timers[name] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1e9)) } catch { return }
            guard let self, !self.stopped else { return }
            self.timers[name] = nil; action()
        }
    }
}
