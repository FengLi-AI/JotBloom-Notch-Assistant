import Foundation

@MainActor
public protocol PanelPresenting: AnyObject {
    @discardableResult
    func present() -> Bool
    func dismiss()
    func prepareForDismissal() -> Bool
}

public extension PanelPresenting { func prepareForDismissal() -> Bool { true } }

@MainActor
public protocol ActivatableApplication: AnyObject {
    var bundleIdentifier: String? { get }
    var isTerminated: Bool { get }

    @discardableResult
    func activateForJotBloom() -> Bool
}

@MainActor
public protocol FrontmostApplicationProviding: AnyObject {
    func frontmostApplication() -> ActivatableApplication?
}

@MainActor
public final class PanelVisibilityCoordinator {
    public private(set) var isVisible = false
    public var onVisibilityChanged: ((Bool) -> Void)?

    private let panel: PanelPresenting
    private let frontmostApplicationProvider: FrontmostApplicationProviding
    private let ownBundleIdentifier: String
    private var previousApplication: ActivatableApplication?

    public init(
        panel: PanelPresenting,
        frontmostApplicationProvider: FrontmostApplicationProviding,
        ownBundleIdentifier: String
    ) {
        self.panel = panel
        self.frontmostApplicationProvider = frontmostApplicationProvider
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    public func show() {
        guard !isVisible else { return }

        let candidate = frontmostApplicationProvider.frontmostApplication()
        previousApplication = candidate?.bundleIdentifier == ownBundleIdentifier ? nil : candidate

        guard panel.present() else {
            previousApplication = nil
            return
        }

        isVisible = true
        onVisibilityChanged?(true)
    }

    public func hide(restoreFocus: Bool = true) {
        guard isVisible else { return }
        guard panel.prepareForDismissal() else { return }

        isVisible = false
        panel.dismiss()
        onVisibilityChanged?(false)

        defer { previousApplication = nil }
        guard restoreFocus,
              let previousApplication,
              !previousApplication.isTerminated else {
            return
        }

        previousApplication.activateForJotBloom()
    }

    public func toggle() {
        isVisible ? hide() : show()
    }
}
