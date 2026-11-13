import AppKit
import JotBloomCore

/// Independent of CompanionController and its enabled preference.
@MainActor
final class PresentationGate {
    var onChange: (() -> Void)?
    var panelIsVisible: () -> Bool = { false }
    private(set) var conditions = IslandPresentationConditions()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var allowsPresentation: Bool { conditions.allowsPresentation }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, center: workspace) { $0.conditions.sleeping = true }
        observe(NSWorkspace.didWakeNotification, center: workspace) { $0.conditions.sleeping = false }
        observe(NSWorkspace.screensDidSleepNotification, center: workspace) { $0.conditions.screenSleeping = true }
        observe(NSWorkspace.screensDidWakeNotification, center: workspace) { $0.conditions.screenSleeping = false }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { $0.conditions.sessionInactive = true }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { $0.conditions.sessionInactive = false }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            observe(name, center: workspace) { _ in }
        }
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) { _ in }
        refresh()
    }
    func refresh() {
        conditions.panelVisible = panelIsVisible()
        conditions.fullScreenState = FullScreenDetector().currentState()
        onChange?()
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter,
                         action: @escaping @MainActor (PresentationGate) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self); self.refresh()
            }
        }
        observers.append((center, token))
    }
    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
    }
}
