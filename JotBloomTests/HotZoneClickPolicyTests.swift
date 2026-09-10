import XCTest
@testable import JotBloomCore

final class HotZoneClickPolicyTests: XCTestCase {
    func testEveryStationaryLeftMouseDownActivatesRegardlessOfClickCount() {
        for clickCount in 1...4 {
            XCTAssertTrue(
                HotZoneClickPolicy.shouldActivate(
                    buttonNumber: 0,
                    clickCount: clickCount
                )
            )
        }
    }

    func testNonLeftMouseButtonsDoNotActivate() {
        XCTAssertFalse(
            HotZoneClickPolicy.shouldActivate(
                buttonNumber: 1,
                clickCount: 1
            )
        )
        XCTAssertFalse(
            HotZoneClickPolicy.shouldActivate(
                buttonNumber: 2,
                clickCount: 1
            )
        )
    }

    func testInvalidClickCountDoesNotActivate() {
        XCTAssertFalse(
            HotZoneClickPolicy.shouldActivate(
                buttonNumber: 0,
                clickCount: 0
            )
        )
    }
}
