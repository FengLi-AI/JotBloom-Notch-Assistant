import AppKit
import JotBloomCore

@MainActor
final class WorkspaceFrontmostApplicationProvider: FrontmostApplicationProviding {
    func frontmostApplication() -> ActivatableApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return RunningApplicationAdapter(application: application)
    }
}
@MainActor
private final class RunningApplicationAdapter: ActivatableApplication {
    private let application: NSRunningApplication

    init(application: NSRunningApplication) {
        self.application = application
    }

    var bundleIdentifier: String? {
        application.bundleIdentifier
    }

    var isTerminated: Bool {
        application.isTerminated
    }

    @discardableResult
    func activateForJotBloom() -> Bool {
        application.activate(options: [.activateIgnoringOtherApps])
    }
}
