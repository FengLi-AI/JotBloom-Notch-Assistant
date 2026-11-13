import AppKit
import JotBloomCore

/// The transparent canvas and the physical notch always pass through to lower windows.
final class IslandHitRegion {
    weak var panel: AssistantIslandPanel?
    var geometry = IslandGeometry(width: 0, height: 0, bottomRadius: 0, shoulderRadius: 0)
    var notch: CGRect?
    var offsetY: CGFloat = 0
    var enabled = false
    var onHover: ((Bool) -> Void)?
    private var hovered = false
    private var revision = 0

    func present(_ value: IslandGeometry) {
        // Called while SwiftUI renders a frame. Never publish back into that render.
        revision += 1
        let revision = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == revision else { return }
            self.geometry = value
            self.update()
        }
    }
    func contains(_ screenPoint: CGPoint) -> Bool {
        guard enabled, let panel, panel.isVisible else { return false }
        let p = CGPoint(x: screenPoint.x - panel.frame.minX,
                        y: panel.frame.maxY - screenPoint.y - offsetY)
        return geometry.contains(p, canvas: CGRect(origin: .zero, size: panel.frame.size), excluding: notch)
    }
    func update() {
        let inside = contains(NSEvent.mouseLocation)
        panel?.ignoresMouseEvents = !inside
        if hovered != inside { hovered = inside; onHover?(inside) }
    }
}
