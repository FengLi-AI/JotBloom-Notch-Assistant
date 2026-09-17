import AppKit
import SwiftUI

/// Optional modules are supplied by the assembling app, never downloaded or
/// required by the public client. Missing modules leave the base app unchanged.
@MainActor
struct ApplicationExtensionContext {
    let defaults: UserDefaults
    let isPanelVisible: () -> Bool
    let showPanel: () -> Void
    let hidePanel: () -> Void
    let showSettings: () -> Void
}

@MainActor
protocol ApplicationExtending: AnyObject {
    init()
    var settingsTitle: String { get }
    var settingsView: AnyView { get }
    func start(context: ApplicationExtensionContext)
    func panelVisibilityDidChange(_ visible: Bool)
    func stop()
}

@MainActor
final class ApplicationExtensionHost: ObservableObject {
    static let shared = ApplicationExtensionHost()
    @Published private(set) var module: (any ApplicationExtending)?

    func start(context: ApplicationExtensionContext) {
        // The host is restarted after storage relocation too. Old closures must
        // not keep pointing at the previous panel/service graph.
        stop()
        guard let name = Bundle.main.object(forInfoDictionaryKey: "JotBloomExtensionPrincipalClass") as? String,
              let factory = NSClassFromString(name) as? any ApplicationExtending.Type else { return }
        let instance = factory.init()
        instance.start(context: context)
        module = instance
        instance.panelVisibilityDidChange(context.isPanelVisible())
    }

    func panelVisibilityDidChange(_ visible: Bool) {
        module?.panelVisibilityDidChange(visible)
    }

    func stop() {
        module?.stop()
        module = nil
    }
}
