import CoreGraphics
import SwiftUI

/// Coordinates are top-down, shared by the rendered surface and mouse hit testing.
public struct IslandGeometry: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public var bottomRadius: CGFloat
    public var shoulderRadius: CGFloat
    public init(width: CGFloat, height: CGFloat, bottomRadius: CGFloat, shoulderRadius: CGFloat) {
        self.width = width; self.height = height
        self.bottomRadius = bottomRadius; self.shoulderRadius = shoulderRadius
    }

    public func path(in canvas: CGRect) -> CGPath {
        let rect = CGRect(x: canvas.midX - max(0, width) / 2, y: canvas.minY,
                          width: max(0, width), height: max(0, height))
        let s = max(0, min(shoulderRadius, rect.height * 0.45))
        let r = max(0, min(bottomRadius, rect.height - s, rect.width / 2))
        if s == 0 {
            // Use the native continuous corners for both drawing and hit testing.
            return RoundedRectangle(cornerRadius: min(r, rect.height / 2), style: .continuous)
                .path(in: rect).cgPath
        }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX - s, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + s, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + s),
                   control1: CGPoint(x: rect.maxX + s * 0.36, y: rect.minY),
                   control2: CGPoint(x: rect.maxX, y: rect.minY + s * 0.4))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + s))
        p.addCurve(to: CGPoint(x: rect.minX - s, y: rect.minY),
                   control1: CGPoint(x: rect.minX, y: rect.minY + s * 0.4),
                   control2: CGPoint(x: rect.minX - s * 0.36, y: rect.minY))
        p.closeSubpath()
        return p
    }

    public func contains(_ point: CGPoint, canvas: CGRect, excluding notch: CGRect?) -> Bool {
        if let notch, notch.contains(point) { return false }
        return path(in: canvas).contains(point)
    }
}

public struct IslandPresentationConditions: Equatable {
    public var panelVisible = false
    public var sleeping = false
    public var screenSleeping = false
    public var sessionInactive = false
    public var fullScreenState: FrontmostFullScreenState = .unknown
    public init() {}
    public var allowsPresentation: Bool {
        !panelVisible && !sleeping && !screenSleeping && !sessionInactive && fullScreenState == .windowed
    }
}
