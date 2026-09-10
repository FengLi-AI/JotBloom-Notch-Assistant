import AppKit
import CoreGraphics
import JotBloomCore

@MainActor
final class FullScreenDetector {
    func currentState() -> FrontmostFullScreenState {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return .unknown
        }

        guard let rawWindowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return .unknown
        }

        let processIdentifier = application.processIdentifier
        let bounds = rawWindowList.compactMap { windowInfo -> CGRect? in
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == processIdentifier,
                  let layer = windowInfo[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0 else {
                return nil
            }
            return Self.windowBounds(from: windowInfo[kCGWindowBounds as String])
        }

        return FullScreenHeuristics.evaluate(
            frontmostWindowBounds: bounds,
            screenFrames: NSScreen.screens.map(\.frame)
        )
    }

    private static func windowBounds(from rawValue: Any?) -> CGRect? {
        guard let dictionary = rawValue as? [String: Any],
              let x = dictionary["X"] as? NSNumber,
              let y = dictionary["Y"] as? NSNumber,
              let width = dictionary["Width"] as? NSNumber,
              let height = dictionary["Height"] as? NSNumber else {
            return nil
        }

        return CGRect(
            x: x.doubleValue,
            y: y.doubleValue,
            width: width.doubleValue,
            height: height.doubleValue
        )
    }
}
