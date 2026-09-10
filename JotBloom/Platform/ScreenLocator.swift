import AppKit
import JotBloomCore

enum ScreenLocator {
    static func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func metrics(for screen: NSScreen) -> ScreenMetrics {
        ScreenMetrics(
            frame: screen.frame,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            statusBarThickness: NSStatusBar.system.thickness
        )
    }
}
