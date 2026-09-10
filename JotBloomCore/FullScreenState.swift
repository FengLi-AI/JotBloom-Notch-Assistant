import CoreGraphics
import Foundation

public enum FrontmostFullScreenState: Equatable {
    case fullScreen
    case windowed
    case unknown
}

public enum FullScreenHeuristics {
    public static func evaluate(
        frontmostWindowBounds: [CGRect]?,
        screenFrames: [CGRect],
        tolerance: CGFloat = 2
    ) -> FrontmostFullScreenState {
        guard let frontmostWindowBounds else { return .unknown }

        let hasFullScreenWindow = frontmostWindowBounds.contains { window in
            screenFrames.contains { screen in
                abs(window.width - screen.width) <= tolerance
                    && abs(window.height - screen.height) <= tolerance
            }
        }

        return hasFullScreenWindow ? .fullScreen : .windowed
    }
}
public enum HotZoneAvailabilityPolicy {
    public static func isEnabled(
        panelVisible: Bool,
        hasPhysicalNotch: Bool,
        fullScreenState: FrontmostFullScreenState
    ) -> Bool {
        guard fullScreenState == .windowed else { return false }
        return !panelVisible || hasPhysicalNotch
    }
}
