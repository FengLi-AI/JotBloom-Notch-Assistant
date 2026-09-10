import CoreGraphics
import Foundation

public struct ScreenMetrics: Equatable {
    public let frame: CGRect
    public let auxiliaryTopLeftArea: CGRect?
    public let auxiliaryTopRightArea: CGRect?
    public let statusBarThickness: CGFloat

    public init(
        frame: CGRect,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        statusBarThickness: CGFloat
    ) {
        self.frame = frame
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.statusBarThickness = statusBarThickness
    }
}
public enum PanelGeometry {
    public static let referenceScreenSize = CGSize(width: 1_470, height: 956)
    public static let referencePanelSize = CGSize(width: 640, height: 300)
    public static let referenceExpandedHeight: CGFloat = 700
    public static let fallbackNotchWidth: CGFloat = 175
    public static let fallbackHotZoneHorizontalInset: CGFloat = 8
    public static let fallbackHotZoneHeight: CGFloat = 28
    public static let referenceInspirationInputHeight: CGFloat = 183
    public static let inspirationContentVerticalPadding: CGFloat = 32
    public static let inspirationInputButtonSpacing: CGFloat = 12
    public static let inspirationButtonRowHeight: CGFloat = 36

    public static func notchHeight(for metrics: ScreenMetrics) -> CGFloat {
        physicalNotchFrame(for: metrics)?.height ?? metrics.statusBarThickness
    }

    public static func notchWidth(for metrics: ScreenMetrics) -> CGFloat {
        physicalNotchFrame(for: metrics)?.width ?? fallbackNotchWidth
    }

    public static func physicalNotchFrame(for metrics: ScreenMetrics) -> CGRect? {
        guard let left = metrics.auxiliaryTopLeftArea,
              let right = metrics.auxiliaryTopRightArea else {
            return nil
        }

        let width = right.minX - left.maxX
        let height = max(left.height, right.height)
        guard width > 0,
              height > 0,
              height <= metrics.frame.height,
              left.maxX >= metrics.frame.minX,
              right.minX <= metrics.frame.maxX else {
            return nil
        }

        return CGRect(
            x: left.maxX,
            y: metrics.frame.maxY - height,
            width: width,
            height: height
        )
    }

    public static func scale(for metrics: ScreenMetrics) -> CGFloat {
        let rawScale = min(
            metrics.frame.width / referenceScreenSize.width,
            metrics.frame.height / referenceScreenSize.height
        )
        return min(1.2, max(0.85, rawScale))
    }

    public static func panelFrame(for metrics: ScreenMetrics, expanded: Bool = false) -> CGRect {
        let scale = scale(for: metrics)
        let width = referencePanelSize.width * scale
        let baseHeight = expanded ? referenceExpandedHeight : referencePanelSize.height
        let height = baseHeight * scale

        return CGRect(
            x: metrics.frame.midX - width / 2,
            y: metrics.frame.maxY - height,
            width: width,
            height: height
        )
    }

    public static func inspirationInputHeight(for metrics: ScreenMetrics) -> CGFloat {
        let panelScale = scale(for: metrics)
        guard panelScale < 1 else {
            return referenceInspirationInputHeight
        }

        let normalPanelHeight = referencePanelSize.height * panelScale
        let availableHeight = normalPanelHeight
            - notchHeight(for: metrics)
            - inspirationContentVerticalPadding
            - inspirationInputButtonSpacing
            - inspirationButtonRowHeight

        return max(44, min(referenceInspirationInputHeight, availableHeight))
    }

    public static func hotZoneFrame(for metrics: ScreenMetrics) -> CGRect {
        if let physicalNotchFrame = physicalNotchFrame(for: metrics) {
            return physicalNotchFrame
        }

        let width = max(
            1,
            fallbackNotchWidth - fallbackHotZoneHorizontalInset * 2
        )
        let height = fallbackHotZoneHeight

        return CGRect(
            x: metrics.frame.midX - width / 2,
            y: metrics.frame.maxY - metrics.statusBarThickness - height,
            width: width,
            height: height
        )
    }
}
