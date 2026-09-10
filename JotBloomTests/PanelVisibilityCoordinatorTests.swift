import XCTest
@testable import JotBloomCore

@MainActor
final class PanelVisibilityCoordinatorTests: XCTestCase {
    func testToggleShowsThenHidesAndRestoresPreviousApplication() {
        let panel = PanelSpy()
        let application = ApplicationSpy(bundleIdentifier: "com.example.editor")
        let provider = FrontmostProviderSpy(application: application)
        let subject = PanelVisibilityCoordinator(
            panel: panel,
            frontmostApplicationProvider: provider,
            ownBundleIdentifier: "com.jotbloom.mengsheng"
        )

        subject.toggle()
        subject.toggle()

        XCTAssertEqual(panel.presentCallCount, 1)
        XCTAssertEqual(panel.dismissCallCount, 1)
        XCTAssertEqual(provider.readCallCount, 1)
        XCTAssertEqual(application.activateCallCount, 1)
        XCTAssertFalse(subject.isVisible)
    }

    func testRepeatedShowDoesNotReplaceOriginalApplication() {
        let panel = PanelSpy()
        let firstApplication = ApplicationSpy(bundleIdentifier: "com.example.first")
        let secondApplication = ApplicationSpy(bundleIdentifier: "com.example.second")
        let provider = FrontmostProviderSpy(applications: [firstApplication, secondApplication])
        let subject = PanelVisibilityCoordinator(
            panel: panel,
            frontmostApplicationProvider: provider,
            ownBundleIdentifier: "com.jotbloom.mengsheng"
        )

        subject.show()
        subject.show()
        subject.hide()

        XCTAssertEqual(provider.readCallCount, 1)
        XCTAssertEqual(firstApplication.activateCallCount, 1)
        XCTAssertEqual(secondApplication.activateCallCount, 0)
    }

    func testHideDoesNotActivateTerminatedApplication() {
        let panel = PanelSpy()
        let application = ApplicationSpy(bundleIdentifier: "com.example.editor", isTerminated: true)
        let provider = FrontmostProviderSpy(application: application)
        let subject = PanelVisibilityCoordinator(
            panel: panel,
            frontmostApplicationProvider: provider,
            ownBundleIdentifier: "com.jotbloom.mengsheng"
        )

        subject.show()
        subject.hide()

        XCTAssertEqual(application.activateCallCount, 0)
    }

    func testOwnApplicationIsNeverUsedAsRestoreTarget() {
        let panel = PanelSpy()
        let application = ApplicationSpy(bundleIdentifier: "com.jotbloom.mengsheng")
        let provider = FrontmostProviderSpy(application: application)
        let subject = PanelVisibilityCoordinator(
            panel: panel,
            frontmostApplicationProvider: provider,
            ownBundleIdentifier: "com.jotbloom.mengsheng"
        )

        subject.show()
        subject.hide()

        XCTAssertEqual(application.activateCallCount, 0)
    }

    func testHideCanSkipFocusRestorationForAutomatedShutdown() {
        let panel = PanelSpy()
        let application = ApplicationSpy(bundleIdentifier: "com.example.editor")
        let provider = FrontmostProviderSpy(application: application)
        let subject = PanelVisibilityCoordinator(
            panel: panel,
            frontmostApplicationProvider: provider,
            ownBundleIdentifier: "com.jotbloom.mengsheng"
        )

        subject.show()
        subject.hide(restoreFocus: false)

        XCTAssertEqual(application.activateCallCount, 0)
        XCTAssertFalse(subject.isVisible)
    }

    func testVisibilityCallbackTracksOnlyRealTransitions() {
        let panel = PanelSpy()
        let provider = FrontmostProviderSpy(application: nil)
        let subject = PanelVisibilityCoordinator(
            panel: panel,
            frontmostApplicationProvider: provider,
            ownBundleIdentifier: "com.jotbloom.mengsheng"
        )
        var values: [Bool] = []
        subject.onVisibilityChanged = { values.append($0) }

        subject.show()
        subject.show()
        subject.hide()
        subject.hide()

        XCTAssertEqual(values, [true, false])
    }

    func testFailedPresentationDoesNotEnterVisibleStateOrHideHotZone() {
        let panel = PanelSpy(presentationSucceeds: false)
        let provider = FrontmostProviderSpy(application: nil)
        let subject = PanelVisibilityCoordinator(
            panel: panel,
            frontmostApplicationProvider: provider,
            ownBundleIdentifier: "com.jotbloom.mengsheng"
        )
        var values: [Bool] = []
        subject.onVisibilityChanged = { values.append($0) }

        subject.show()

        XCTAssertFalse(subject.isVisible)
        XCTAssertEqual(values, [])
        XCTAssertEqual(panel.presentCallCount, 1)
    }
}

@MainActor
private final class PanelSpy: PanelPresenting {
    private let presentationSucceeds: Bool
    private(set) var presentCallCount = 0
    private(set) var dismissCallCount = 0

    init(presentationSucceeds: Bool = true) {
        self.presentationSucceeds = presentationSucceeds
    }

    @discardableResult
    func present() -> Bool {
        presentCallCount += 1
        return presentationSucceeds
    }

    func dismiss() {
        dismissCallCount += 1
    }
}

@MainActor
private final class ApplicationSpy: ActivatableApplication {
    let bundleIdentifier: String?
    let isTerminated: Bool
    private(set) var activateCallCount = 0

    init(bundleIdentifier: String?, isTerminated: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.isTerminated = isTerminated
    }

    @discardableResult
    func activateForJotBloom() -> Bool {
        activateCallCount += 1
        return true
    }
}

@MainActor
private final class FrontmostProviderSpy: FrontmostApplicationProviding {
    private var applications: [ActivatableApplication?]
    private(set) var readCallCount = 0

    init(application: ActivatableApplication?) {
        self.applications = [application]
    }

    init(applications: [ActivatableApplication?]) {
        self.applications = applications
    }

    func frontmostApplication() -> ActivatableApplication? {
        guard !applications.isEmpty else { return nil }
        defer { readCallCount += 1 }
        let index = min(readCallCount, applications.count - 1)
        return applications[index]
    }
}
