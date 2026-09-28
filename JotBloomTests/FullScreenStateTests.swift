import CoreGraphics
import XCTest
@testable import JotBloomCore

final class FullScreenStateTests: XCTestCase {
    func testMatchingWindowAndScreenSizesAreFullScreen() {
        let state = FullScreenHeuristics.evaluate(
            frontmostWindowBounds: [CGRect(x: 0, y: 0, width: 1_470, height: 956)],
            screenFrames: [CGRect(x: 0, y: 0, width: 1_470, height: 956)]
        )

        XCTAssertEqual(state, .fullScreen)
    }

    func testTwoPointToleranceStillCountsAsFullScreen() {
        let state = FullScreenHeuristics.evaluate(
            frontmostWindowBounds: [CGRect(x: 0, y: 0, width: 1_468.5, height: 954.5)],
            screenFrames: [CGRect(x: 0, y: 0, width: 1_470, height: 956)]
        )

        XCTAssertEqual(state, .fullScreen)
    }

    func testMaximizedWindowBelowMenuBarIsWindowed() {
        let state = FullScreenHeuristics.evaluate(
            frontmostWindowBounds: [CGRect(x: 0, y: 0, width: 1_470, height: 932)],
            screenFrames: [CGRect(x: 0, y: 0, width: 1_470, height: 956)]
        )

        XCTAssertEqual(state, .windowed)
    }

    func testUnavailableWindowListIsUnknownAndDisablesHotZone() {
        let state = FullScreenHeuristics.evaluate(
            frontmostWindowBounds: nil,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_470, height: 956)]
        )

        XCTAssertEqual(state, .unknown)
        XCTAssertFalse(
            HotZoneAvailabilityPolicy.isEnabled(
                panelVisible: false,
                hasPhysicalNotch: true,
                fullScreenState: state
            )
        )
    }

    func testVisiblePanelKeepsPhysicalNotchHotZoneEnabled() {
        XCTAssertTrue(
            HotZoneAvailabilityPolicy.isEnabled(
                panelVisible: true,
                hasPhysicalNotch: true,
                fullScreenState: .windowed
            )
        )
    }

    func testNonNotchDisplayNeverEnablesHotZone() {
        for panelVisible in [false, true] {
            for state in [FrontmostFullScreenState.windowed, .fullScreen, .unknown] {
                XCTAssertFalse(
                    HotZoneAvailabilityPolicy.isEnabled(
                        panelVisible: panelVisible,
                        hasPhysicalNotch: false,
                        fullScreenState: state
                    ),
                    "Non-notch display must stay inactive: panelVisible=\(panelVisible), state=\(state)"
                )
            }
        }
    }

    func testHiddenPanelEnablesPhysicalNotchHotZone() {
        XCTAssertTrue(
            HotZoneAvailabilityPolicy.isEnabled(
                panelVisible: false,
                hasPhysicalNotch: true,
                fullScreenState: .windowed
            )
        )
    }

    func testFullScreenDisablesPhysicalNotchEvenWhenPanelIsVisible() {
        XCTAssertFalse(
            HotZoneAvailabilityPolicy.isEnabled(
                panelVisible: true,
                hasPhysicalNotch: true,
                fullScreenState: .fullScreen
            )
        )
    }
}
