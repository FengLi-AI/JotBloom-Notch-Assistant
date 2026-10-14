#!/usr/bin/env python3
"""Exercise the real private motion implementation with layers, without opening an app.

The shadow view is a compile-time stand-in: this checks layer/path state and
reversal continuity, not native window rendering or visual acceptance.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "JotBloom/Platform/PanelController.swift").read_text()
motion = source.split("@MainActor\nprivate final class PanelSurfaceMotion", 1)[1].split("private final class JotBloomPanel", 1)[0]
outline = source.split("private enum PanelOutline", 1)[1].split("private final class PanelEdgeView", 1)[0]
probe = r'''
@main struct Probe {
    @MainActor static func main() {
        let motion = PanelSurfaceMotion(), surface = CALayer(), mask = CAShapeLayer(), content = CALayer()
        let size = CGSize(width: 640, height: 300)
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print("\(name)=\(passed)")
            if !passed { failures += 1 }
        }
        func spin(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) }
        }
        surface.mask = mask
        motion.configure(surface: surface, contents: [content], edge: nil, color: NSColor.black.cgColor)
        motion.layout(on: mask, size: size)
        motion.prepare(from: nil)
        check("active_mask_matches", motion.debugSurfaceAndMaskAgree)
        let activePath = mask.path
        mask.path = CGPath(rect: .zero, transform: nil)
        check("active_corruption_detected", !motion.debugSurfaceAndMaskAgree)
        mask.path = activePath
        motion.finish()
        check("resting_mask_matches", motion.debugSurfaceAndMaskAgree)
        let restingPath = mask.path
        mask.path = CGPath(rect: .zero, transform: nil)
        check("resting_corruption_detected", !motion.debugSurfaceAndMaskAgree)
        mask.path = restingPath
        surface.mask = nil
        check("missing_mask_detected", !motion.debugSurfaceAndMaskAgree)
        surface.mask = mask
        motion.prepare(from: nil)
        motion.animate(opening: true, to: size)
        var throughout = true
        for _ in 0..<240 {
            spin(0.005)
            throughout = throughout && motion.debugSurfaceAndMaskAgree
        }
        check("mask_matches_through_open_and_finish", throughout && !motion.isAnimating)
        check("resting_content_has_native_scale", motion.debugTextHasOriginalScale)
        motion.prepare(from: nil)
        motion.animate(opening: true, to: size)
        spin(0.08)
        let interrupted = motion.snapshot()
        motion.prepare(from: interrupted)
        let resumed = motion.snapshot()
        check("reverse_preserves_position_and_velocity", interrupted.size == resumed.size && interrupted.velocity == resumed.velocity)
        motion.animate(opening: false, to: size)
        spin(0.04)
        let closing = motion.snapshot()
        motion.prepare(from: closing)
        motion.animate(opening: true, to: size)
        throughout = true
        for _ in 0..<240 {
            spin(0.005)
            throughout = throughout && motion.debugSurfaceAndMaskAgree
        }
        check("reverse_settles_with_matching_mask", throughout && !motion.isAnimating)
        exit(failures == 0 ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix="jotbloom-motion-check-") as tmp:
    folder = Path(tmp)
    swift = folder / "Probe.swift"
    swift.write_text("import AppKit\nimport QuartzCore\nimport CoreImage\n"
                     "private final class PanelDropShadowView: NSView { var motionActive = false }\n"
                     "@MainActor\nprivate final class PanelSurfaceMotion" + motion
                     + "private enum PanelOutline" + outline + probe)
    executable = folder / "Probe"
    subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-parse-as-library",
                    "-module-cache-path", str(folder / "module-cache"), str(swift),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
