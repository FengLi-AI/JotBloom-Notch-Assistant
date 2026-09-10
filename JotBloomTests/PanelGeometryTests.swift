import CoreGraphics
import XCTest
@testable import JotBloomCore

final class PanelGeometryTests: XCTestCase {
    func testReferenceScreenProducesReferencePanelSizeAtTopCenter() {
        let metrics = makeMetrics(frame: CGRect(x: 0, y: 0, width: 1_470, height: 956))

        let frame = PanelGeometry.panelFrame(for: metrics)

        XCTAssertEqual(frame.width, 640, accuracy: 0.001)
        XCTAssertEqual(frame.height, 300, accuracy: 0.001)
        XCTAssertEqual(frame.midX, metrics.frame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, metrics.frame.maxY, accuracy: 0.001)
    }

    func testScaleIsClampedAtBothEnds() {
        let small = makeMetrics(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let large = makeMetrics(frame: CGRect(x: 0, y: 0, width: 4_000, height: 3_000))

        XCTAssertEqual(PanelGeometry.scale(for: small), 0.85, accuracy: 0.001)
        XCTAssertEqual(PanelGeometry.scale(for: large), 1.2, accuracy: 0.001)
    }

    func testNotchMetricsDriveHotZoneFrame() {
        let screen = CGRect(x: 100, y: 50, width: 1_470, height: 956)
        let metrics = ScreenMetrics(
            frame: screen,
            auxiliaryTopLeftArea: CGRect(x: 100, y: 969, width: 647.5, height: 37),
            auxiliaryTopRightArea: CGRect(x: 922.5, y: 969, width: 647.5, height: 37),
            statusBarThickness: 24
        )

        let frame = PanelGeometry.hotZoneFrame(for: metrics)

        XCTAssertEqual(PanelGeometry.notchWidth(for: metrics), 175, accuracy: 0.001)
        XCTAssertEqual(frame.minX, 747.5, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 969, accuracy: 0.001)
        XCTAssertEqual(frame.width, 175, accuracy: 0.001)
        XCTAssertEqual(frame.height, 37, accuracy: 0.001)
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.001)
    }

    func testCurrentMacBookAirMetricsProduceExactPhysicalNotchFrame() {
        let metrics = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1_470, height: 956),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
            auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32),
            statusBarThickness: 24
        )

        let frame = PanelGeometry.hotZoneFrame(for: metrics)

        XCTAssertEqual(frame, CGRect(x: 646, y: 924, width: 179, height: 32))
    }

    func testPhysicalNotchUsesGlobalAuxiliaryBoundsOnOffsetScreen() {
        let metrics = ScreenMetrics(
            frame: CGRect(x: -1_920, y: -200, width: 1_920, height: 1_080),
            auxiliaryTopLeftArea: CGRect(x: -1_920, y: 848, width: 840, height: 32),
            auxiliaryTopRightArea: CGRect(x: -900, y: 848, width: 900, height: 32),
            statusBarThickness: 24
        )

        let frame = PanelGeometry.hotZoneFrame(for: metrics)

        XCTAssertEqual(frame, CGRect(x: -1_080, y: 848, width: 180, height: 32))
    }

    func testReferenceScreenKeepsReferenceInspirationInputHeight() {
        let metrics = makeMetrics(frame: CGRect(x: 0, y: 0, width: 1_470, height: 956))

        XCTAssertEqual(
            PanelGeometry.inspirationInputHeight(for: metrics),
            183,
            accuracy: 0.001
        )
    }

    func testScaledNotchScreenCompressesOnlyInspirationInputHeight() {
        let frame = CGRect(x: 0, y: 0, width: 1_280, height: 832)
        let metrics = ScreenMetrics(
            frame: frame,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 795, width: 552.5, height: 37),
            auxiliaryTopRightArea: CGRect(x: 727.5, y: 795, width: 552.5, height: 37),
            statusBarThickness: 24
        )

        let expected = 300 * PanelGeometry.scale(for: metrics) - 37 - 32 - 12 - 36
        XCTAssertEqual(
            PanelGeometry.inspirationInputHeight(for: metrics),
            expected,
            accuracy: 0.001
        )
        XCTAssertLessThan(expected, PanelGeometry.referenceInspirationInputHeight)
    }

    func testNonNotchScreenUsesStatusBarAndFallbackWidth() {
        let metrics = makeMetrics(
            frame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
            statusBarThickness: 24
        )

        let frame = PanelGeometry.hotZoneFrame(for: metrics)

        XCTAssertEqual(PanelGeometry.notchWidth(for: metrics), 175, accuracy: 0.001)
        XCTAssertEqual(PanelGeometry.notchHeight(for: metrics), 24, accuracy: 0.001)
        XCTAssertEqual(frame.width, 159, accuracy: 0.001)
        XCTAssertEqual(frame.height, 28, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, metrics.frame.maxY - 24, accuracy: 0.001)
    }

    func testInvalidAuxiliaryAreasUseNonNotchFallback() {
        let screen = CGRect(x: 100, y: 50, width: 1_470, height: 956)
        let metrics = ScreenMetrics(
            frame: screen,
            auxiliaryTopLeftArea: CGRect(x: 100, y: 1_006, width: 800, height: 0),
            auxiliaryTopRightArea: CGRect(x: 850, y: 1_006, width: 720, height: 0),
            statusBarThickness: 24
        )

        let frame = PanelGeometry.hotZoneFrame(for: metrics)

        XCTAssertNil(PanelGeometry.physicalNotchFrame(for: metrics))
        XCTAssertEqual(PanelGeometry.notchWidth(for: metrics), 175, accuracy: 0.001)
        XCTAssertEqual(PanelGeometry.notchHeight(for: metrics), 24, accuracy: 0.001)
        XCTAssertEqual(frame.width, 159, accuracy: 0.001)
        XCTAssertEqual(frame.height, 28, accuracy: 0.001)
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, screen.maxY - 24, accuracy: 0.001)
    }

    private func makeMetrics(
        frame: CGRect,
        statusBarThickness: CGFloat = 24
    ) -> ScreenMetrics {
        ScreenMetrics(
            frame: frame,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            statusBarThickness: statusBarThickness
        )
    }
}
