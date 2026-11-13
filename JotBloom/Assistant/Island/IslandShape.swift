import SwiftUI
import JotBloomCore

struct IslandShape: Shape {
    var geometry: IslandGeometry
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(geometry.width, geometry.height), .init(geometry.bottomRadius, geometry.shoulderRadius)) }
        set {
            geometry.width = newValue.first.first; geometry.height = newValue.first.second
            geometry.bottomRadius = newValue.second.first; geometry.shoulderRadius = newValue.second.second
        }
    }
    func path(in rect: CGRect) -> Path { Path(geometry.path(in: rect)) }
}

/// Reports the interpolated shape, rather than the destination rectangle, to AppKit.
/// This changes no SwiftUI state and does not drive animation or resize the window.
struct IslandSurface: View, Animatable {
    var geometry: IslandGeometry
    let floating: Bool
    let hitRegion: IslandHitRegion
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { IslandShape(geometry: geometry).animatableData }
        set {
            var shape = IslandShape(geometry: geometry)
            shape.animatableData = newValue; geometry = shape.geometry
        }
    }
    var body: some View {
        let _ = hitRegion.present(geometry)
        IslandShape(geometry: geometry)
            .fill(IslandTheme.background)
            .overlay {
                if floating { IslandShape(geometry: geometry).stroke(IslandTheme.hairline, lineWidth: 0.5) }
            }
    }
}

struct IslandNotchRim: Shape {
    var width: CGFloat
    var height: CGFloat
    func path(in rect: CGRect) -> Path {
        let l = rect.midX - width / 2, r = rect.midX + width / 2
        let b = height + 0.75, radius: CGFloat = 10
        var p = Path()
        p.move(to: CGPoint(x: l - 1, y: 0)); p.addLine(to: CGPoint(x: l - 1, y: b - radius))
        p.addQuadCurve(to: CGPoint(x: l + radius, y: b), control: CGPoint(x: l - 1, y: b))
        p.addLine(to: CGPoint(x: r - radius, y: b))
        p.addQuadCurve(to: CGPoint(x: r + 1, y: b - radius), control: CGPoint(x: r + 1, y: b))
        p.addLine(to: CGPoint(x: r + 1, y: 0))
        return p
    }
}
