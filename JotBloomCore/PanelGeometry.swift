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

/// Uses the actual content proposal, not the screen scale, so rows remain complete.
public struct LibraryLayoutMetrics: Equatable {
    public enum ContentKind: CaseIterable, Hashable { case clipboard, prompts, inspirations, files }
    public let showsSidebar: Bool
    public let sidebarReveal: CGFloat
    public let sidebarWidth: CGFloat
    public let gridWidth: CGFloat
    public let gridHeight: CGFloat
    public let columns: Int
    public let rows: Int
    public let cardHeight: CGFloat
    public let gap: CGFloat = 8

    public init(size: CGSize, expanded: Bool, kind: ContentKind) {
        showsSidebar = expanded && size.height > 340 && size.width >= 460
        sidebarReveal = showsSidebar ? 1 : 0
        sidebarWidth = showsSidebar ? min(112, max(96, size.width * 0.18)) : 0
        gridWidth = max(1, size.width - (showsSidebar ? sidebarWidth + 16 : 0))
        gridHeight = max(1, size.height - (showsSidebar ? 0 : 30))
        switch kind {
        case .clipboard:
            columns = max(1, min(4, Int((gridWidth + 8) / 164)))
        case .prompts:
            columns = gridWidth >= 680 ? 3 : gridWidth >= 360 ? 2 : 1
        case .inspirations:
            columns = 1
        case .files:
            columns = max(1, Int((gridWidth + 8) / 110))
        }
        if kind == .files {
            cardHeight = min(112, max(48, floor((gridHeight - 8) / 2)))
            rows = max(1, Int((gridHeight + 8) / (cardHeight + 8)))
            return
        }
        if showsSidebar {
            let preferred: CGFloat = kind == .clipboard ? 144 : kind == .prompts ? 124 : 76
            let nearest = max(1, Int(((gridHeight + 8) / (preferred + 8)).rounded()))
            let proposedHeight = (gridHeight - CGFloat(nearest - 1) * 8) / CGFloat(nearest)
            rows = proposedHeight > preferred * 1.08 ? nearest + 1 : nearest
        } else {
            rows = kind == .inspirations ? 3 : 2
        }
        cardHeight = max(1, floor((gridHeight - CGFloat(rows - 1) * 8) / CGFloat(rows)))
    }
    /// Interpolate endpoint sizes rather than reselecting a row count on every animation frame.
    public init(from: Self, to: Self, progress: CGFloat) {
        let p = min(1, max(0, progress))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        sidebarReveal = mix(from.sidebarReveal, to.sidebarReveal)
        showsSidebar = sidebarReveal >= 0.5
        sidebarWidth = mix(from.sidebarWidth, to.sidebarWidth)
        gridWidth = mix(from.gridWidth, to.gridWidth)
        gridHeight = mix(from.gridHeight, to.gridHeight)
        cardHeight = mix(from.cardHeight, to.cardHeight)
        columns = p < 0.5 ? from.columns : to.columns
        rows = p < 0.5 ? from.rows : to.rows
    }

}


/// An interrupted resize starts at the currently rendered metrics, never at an old endpoint.
public struct LibraryLayoutTransition: Equatable {
    private let start: [LibraryLayoutMetrics.ContentKind: LibraryLayoutMetrics]
    private let end: [LibraryLayoutMetrics.ContentKind: LibraryLayoutMetrics]
    public var progress: CGFloat = 0

    public init(fromSize: CGSize, toSize: CGSize, wasExpanded: Bool, expanded: Bool, previous: Self? = nil) {
        start = Dictionary(uniqueKeysWithValues: LibraryLayoutMetrics.ContentKind.allCases.map {
            ($0, previous?.layout(for: $0) ?? LibraryLayoutMetrics(size: fromSize, expanded: wasExpanded, kind: $0))
        })
        end = Dictionary(uniqueKeysWithValues: LibraryLayoutMetrics.ContentKind.allCases.map {
            ($0, LibraryLayoutMetrics(size: toSize, expanded: expanded, kind: $0))
        })
    }
    public func layout(for kind: LibraryLayoutMetrics.ContentKind) -> LibraryLayoutMetrics {
        .init(from: start[kind]!, to: end[kind]!, progress: progress)
    }
    public func changesColumns(for kind: LibraryLayoutMetrics.ContentKind) -> Bool {
        start[kind]!.columns != end[kind]!.columns
    }
    public func destination(for kind: LibraryLayoutMetrics.ContentKind) -> LibraryLayoutMetrics {
        end[kind]!
    }
}
