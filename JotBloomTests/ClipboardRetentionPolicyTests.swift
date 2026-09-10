import XCTest
@testable import JotBloomCore

final class ClipboardRetentionPolicyTests: XCTestCase {
    func testUnlimitedPolicyDeletesNothing() {
        let items = [
            ClipboardTestFixtures.item(id: 1, byteCount: 100, copiedAt: 1),
            ClipboardTestFixtures.item(id: 2, byteCount: 100, copiedAt: 2)
        ]
        XCTAssertEqual(
            ClipboardCleanupPlanner.identifiersToDelete(
                from: items,
                policy: ClipboardRetentionPolicy(
                    maximumCount: nil,
                    maximumAgeMilliseconds: nil,
                    maximumBytes: nil
                ),
                nowUTCms: 10_000
            ),
            []
        )
    }

    func testAgeDeletesOnlyItemsStrictlyOlderThanCutoff() {
        let items = [
            ClipboardTestFixtures.item(id: 1, copiedAt: 899),
            ClipboardTestFixtures.item(id: 2, copiedAt: 900),
            ClipboardTestFixtures.item(id: 3, copiedAt: 901)
        ]
        XCTAssertEqual(
            ClipboardCleanupPlanner.identifiersToDelete(
                from: items,
                policy: ClipboardRetentionPolicy(
                    maximumCount: nil,
                    maximumAgeMilliseconds: 100,
                    maximumBytes: nil
                ),
                nowUTCms: 1_000
            ),
            [1]
        )
    }

    func testCountUsesStableTimestampThenIdentifierOrder() {
        let items = [
            ClipboardTestFixtures.item(id: 3, copiedAt: 20),
            ClipboardTestFixtures.item(id: 2, copiedAt: 10),
            ClipboardTestFixtures.item(id: 1, copiedAt: 10)
        ]
        XCTAssertEqual(
            ClipboardCleanupPlanner.identifiersToDelete(
                from: items,
                policy: ClipboardRetentionPolicy(
                    maximumCount: 1,
                    maximumAgeMilliseconds: nil,
                    maximumBytes: nil
                ),
                nowUTCms: 100
            ),
            [1, 2]
        )
    }

    func testCapacityDropsToHalfAfterCrossingLimit() {
        let items = [
            ClipboardTestFixtures.item(id: 1, byteCount: 40, copiedAt: 1),
            ClipboardTestFixtures.item(id: 2, byteCount: 40, copiedAt: 2),
            ClipboardTestFixtures.item(id: 3, byteCount: 40, copiedAt: 3)
        ]
        XCTAssertEqual(
            ClipboardCleanupPlanner.identifiersToDelete(
                from: items,
                policy: ClipboardRetentionPolicy(
                    maximumCount: nil,
                    maximumAgeMilliseconds: nil,
                    maximumBytes: 100
                ),
                nowUTCms: 100
            ),
            [1, 2]
        )
    }

    func testCapacityAtLimitDoesNotDelete() {
        let items = [
            ClipboardTestFixtures.item(id: 1, byteCount: 50, copiedAt: 1),
            ClipboardTestFixtures.item(id: 2, byteCount: 50, copiedAt: 2)
        ]
        XCTAssertEqual(
            ClipboardCleanupPlanner.identifiersToDelete(
                from: items,
                policy: ClipboardRetentionPolicy(
                    maximumCount: nil,
                    maximumAgeMilliseconds: nil,
                    maximumBytes: 100
                ),
                nowUTCms: 100
            ),
            []
        )
    }

    func testCapacityOneByteOverLimitStillDropsToHalf() {
        let items = [
            ClipboardTestFixtures.item(id: 1, byteCount: 26, copiedAt: 1),
            ClipboardTestFixtures.item(id: 2, byteCount: 25, copiedAt: 2),
            ClipboardTestFixtures.item(id: 3, byteCount: 50, copiedAt: 3)
        ]
        XCTAssertEqual(
            ClipboardCleanupPlanner.identifiersToDelete(
                from: items,
                policy: ClipboardRetentionPolicy(
                    maximumCount: nil,
                    maximumAgeMilliseconds: nil,
                    maximumBytes: 100
                ),
                nowUTCms: 100
            ),
            [1, 2]
        )
    }

    func testCombinedPolicyAppliesAgeThenCountThenCapacity() {
        let items = [
            ClipboardTestFixtures.item(id: 1, byteCount: 20, copiedAt: 1),
            ClipboardTestFixtures.item(id: 2, byteCount: 40, copiedAt: 90),
            ClipboardTestFixtures.item(id: 3, byteCount: 40, copiedAt: 91),
            ClipboardTestFixtures.item(id: 4, byteCount: 40, copiedAt: 92)
        ]
        XCTAssertEqual(
            ClipboardCleanupPlanner.identifiersToDelete(
                from: items,
                policy: ClipboardRetentionPolicy(
                    maximumCount: 3,
                    maximumAgeMilliseconds: 95,
                    maximumBytes: 100
                ),
                nowUTCms: 100
            ),
            [1, 2, 3]
        )
    }
}
