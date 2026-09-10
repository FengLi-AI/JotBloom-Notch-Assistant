import XCTest
@testable import JotBloomCore

final class ClipboardSourceSelectorTests: XCTestCase {
    func testFrontmostApplicationIsUsedWhenPanelIsNotKey() {
        let own = ClipboardSourceApplication(
            name: "JotBloom",
            bundleIdentifier: "com.jotbloom.mengsheng"
        )
        let frontmost = ClipboardSourceApplication(
            name: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit"
        )

        XCTAssertEqual(
            ClipboardSourceSelector.select(
                panelIsKey: false,
                ownApplication: own,
                frontmostApplication: frontmost
            ),
            frontmost
        )
    }

    func testOwnApplicationIsUsedWhenPanelIsKey() {
        let own = ClipboardSourceApplication(
            name: "JotBloom",
            bundleIdentifier: "com.jotbloom.mengsheng"
        )
        XCTAssertEqual(
            ClipboardSourceSelector.select(
                panelIsKey: true,
                ownApplication: own,
                frontmostApplication: ClipboardSourceApplication(
                    name: "Other",
                    bundleIdentifier: "com.example.other"
                )
            ),
            own
        )
    }

    func testMissingFrontmostApplicationStaysEmpty() {
        XCTAssertEqual(
            ClipboardSourceSelector.select(
                panelIsKey: false,
                ownApplication: ClipboardSourceApplication(
                    name: "JotBloom",
                    bundleIdentifier: "com.jotbloom.mengsheng"
                ),
                frontmostApplication: nil
            ),
            ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        )
    }
}
