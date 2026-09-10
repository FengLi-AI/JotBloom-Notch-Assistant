import Foundation
import XCTest
@testable import JotBloomCore

final class InspirationStoreTests: XCTestCase {
    func testCursorPaginationIsStableForOneHundredAndOneEqualTimestamps() throws {
        let fixture = try makeFixture(count: 101, timestamp: 1_000)
        defer { fixture.closeAndRemove() }

        let first = try fixture.store.listInspirationsPageSynchronously()
        let second = try fixture.store.listInspirationsPageSynchronously(
            after: first.nextCursor
        )
        let third = try fixture.store.listInspirationsPageSynchronously(
            after: second.nextCursor
        )

        XCTAssertEqual(first.items.count, 50)
        XCTAssertEqual(second.items.count, 50)
        XCTAssertEqual(third.items.count, 1)
        XCTAssertEqual(first.items.map(\.id), (52...101).reversed().map(Int64.init))
        XCTAssertEqual(second.items.map(\.id), (2...51).reversed().map(Int64.init))
        XCTAssertEqual(third.items.map(\.id), [1])
        XCTAssertNotNil(first.nextCursor)
        XCTAssertNotNil(second.nextCursor)
        XCTAssertNil(third.nextCursor)
        XCTAssertEqual(Set((first.items + second.items + third.items).map(\.id)).count, 101)
    }

    func testPageBoundariesReportWhetherMoreRecordsExist() throws {
        for count in [0, 1, 49, 50, 51, 100, 101] {
            let fixture = try makeFixture(count: count, timestamp: 2_000)
            defer { fixture.closeAndRemove() }

            let first = try fixture.store.listInspirationsPageSynchronously()
            XCTAssertEqual(first.items.count, min(count, 50), "count=\(count)")
            XCTAssertEqual(first.hasMore, count > 50, "count=\(count)")
            if count > 50 {
                let second = try fixture.store.listInspirationsPageSynchronously(
                    after: first.nextCursor
                )
                XCTAssertEqual(second.items.count, min(count - 50, 50), "count=\(count)")
                XCTAssertEqual(second.hasMore, count > 100, "count=\(count)")
            }
        }
    }

    func testPageLimitIsClampedToOneThroughOneHundred() throws {
        let fixture = try makeFixture(count: 101, timestamp: 3_000)
        defer { fixture.closeAndRemove() }

        let minimum = try fixture.store.listInspirationsPageSynchronously(limit: 0)
        let maximum = try fixture.store.listInspirationsPageSynchronously(limit: 1_000)

        XCTAssertEqual(minimum.items.count, 1)
        XCTAssertTrue(minimum.hasMore)
        XCTAssertEqual(maximum.items.count, 100)
        XCTAssertTrue(maximum.hasMore)
    }

    func testOldCursorExcludesRecordMovedAheadUntilFirstPageRefresh() throws {
        let fixture = try makeFixtureWithIncreasingTimestamps(count: 60)
        defer { fixture.closeAndRemove() }

        let first = try fixture.store.listInspirationsPageSynchronously()
        XCTAssertEqual(first.items.count, 50)
        XCTAssertFalse(first.items.contains { $0.id == 5 })

        _ = try fixture.store.updateInspirationTextSynchronously(
            id: 5,
            title: "移到第一页",
            body: "游标快照之后更新",
            updatedAtUTCms: 10_000
        )
        let continuation = try fixture.store.listInspirationsPageSynchronously(
            after: first.nextCursor
        )
        let refreshed = try fixture.store.listInspirationsPageSynchronously()

        // Since Stage 7, edits preserve manual order rather than jumping to the top.
        XCTAssertTrue(continuation.items.contains { $0.id == 5 })
        XCTAssertEqual(refreshed.items.first?.id, 60)
        XCTAssertEqual(Set((first.items + continuation.items).map(\.id)).count, 60)
    }

    func testReadAndTextUpdatePreserveMetadataAndAdvanceTimeMonotonically() throws {
        let fixture = try makeFixture(count: 1, timestamp: 10_000)
        defer { fixture.closeAndRemove() }
        let original = try fixture.store.inspirationSynchronously(id: 1)

        let updated = try fixture.store.updateInspirationTextSynchronously(
            id: original.id,
            title: "新标题 ' 🌱\0",
            body: "新正文 %\n第二行\0尾",
            updatedAtUTCms: 1
        )

        XCTAssertEqual(updated.title, "新标题 ' 🌱\0")
        XCTAssertEqual(updated.body, "新正文 %\n第二行\0尾")
        XCTAssertEqual(updated.updatedAtUTCms, original.updatedAtUTCms + 1)
        XCTAssertEqual(updated.createdAtUTCms, original.createdAtUTCms)
        XCTAssertEqual(updated.category, original.category)
        XCTAssertEqual(updated.categorySource, original.categorySource)
        XCTAssertEqual(updated.source, original.source)
        XCTAssertEqual(try fixture.store.inspirationSynchronously(id: 1), updated)
    }

    func testTextNoOpDoesNotChangeTimestamp() throws {
        let fixture = try makeFixture(count: 1, timestamp: 20_000)
        defer { fixture.closeAndRemove() }
        let original = try fixture.store.inspirationSynchronously(id: 1)

        let unchanged = try fixture.store.updateInspirationTextSynchronously(
            id: original.id,
            title: original.title,
            body: original.body,
            updatedAtUTCms: 99_999
        )

        XCTAssertEqual(unchanged, original)
    }

    func testCategoryUpdateMarksUserSourceAndDoesNotOverwriteText() throws {
        let fixture = try makeFixture(count: 1, timestamp: 30_000)
        defer { fixture.closeAndRemove() }
        let original = try fixture.store.inspirationSynchronously(id: 1)

        let updated = try fixture.store.updateInspirationCategorySynchronously(
            id: original.id,
            category: .article,
            updatedAtUTCms: original.updatedAtUTCms
        )

        XCTAssertEqual(updated.category, .article)
        XCTAssertEqual(updated.categorySource, .user)
        XCTAssertEqual(updated.updatedAtUTCms, original.updatedAtUTCms + 1)
        XCTAssertEqual(updated.title, original.title)
        XCTAssertEqual(updated.body, original.body)
        XCTAssertEqual(updated.createdAtUTCms, original.createdAtUTCms)
        XCTAssertEqual(updated.source, original.source)
    }

    func testExplicitCategorySelectionClaimsManualOwnershipThenIsNoOp() throws {
        let fixture = try makeFixture(count: 1, timestamp: 40_000)
        defer { fixture.closeAndRemove() }
        let original = try fixture.store.inspirationSynchronously(id: 1)
        XCTAssertEqual(original.categorySource, .fallback)

        let unchanged = try fixture.store.updateInspirationCategorySynchronously(
            id: original.id,
            category: original.category,
            updatedAtUTCms: 99_999
        )

        XCTAssertEqual(unchanged.categorySource, .user)
        XCTAssertEqual(unchanged.body, original.body)
        XCTAssertEqual(unchanged.category, original.category)
        XCTAssertEqual(try fixture.store.updateInspirationCategorySynchronously(id: original.id, category: original.category, updatedAtUTCms: 100_000), unchanged)
    }

    func testTextAndCategoryUpdatesUseSeparateColumns() throws {
        let fixture = try makeFixture(count: 1, timestamp: 50_000)
        defer { fixture.closeAndRemove() }

        let categoryUpdated = try fixture.store.updateInspirationCategorySynchronously(
            id: 1,
            category: .product,
            updatedAtUTCms: 50_000
        )
        let textUpdated = try fixture.store.updateInspirationTextSynchronously(
            id: 1,
            title: "独立文本更新",
            body: "不覆盖分类",
            updatedAtUTCms: 50_000
        )

        XCTAssertEqual(textUpdated.category, .product)
        XCTAssertEqual(textUpdated.categorySource, .user)
        XCTAssertEqual(textUpdated.updatedAtUTCms, categoryUpdated.updatedAtUTCms + 1)
    }

    func testDeleteAndRestoreRoundTripEveryFieldAcrossReopen() throws {
        let fixture = try makeFixture(count: 1, timestamp: 60_000)
        let categorized = try fixture.store.updateInspirationCategorySynchronously(
            id: 1,
            category: .work,
            updatedAtUTCms: 60_001
        )
        let expected = try fixture.store.updateInspirationTextSynchronously(
            id: 1,
            title: "恢复 '🌿\0",
            body: "原样恢复 %\n\0",
            updatedAtUTCms: categorized.updatedAtUTCms + 1
        )

        let deleted = try fixture.store.deleteInspirationSynchronously(id: 1)
        XCTAssertEqual(deleted, expected)
        XCTAssertThrowsError(try fixture.store.inspirationSynchronously(id: 1)) { error in
            XCTAssertEqual(error as? PersistenceError, .inspirationNotFound(id: 1))
        }
        XCTAssertEqual(
            try fixture.store.restoreInspirationSynchronously(deleted),
            expected
        )
        fixture.store.close()

        let reopened = try JotBloomStore(dataDirectoryURL: fixture.directory)
        XCTAssertEqual(try reopened.inspirationSynchronously(id: 1), expected)
        XCTAssertEqual(try reopened.schemaVersionSynchronously(), 7)
        reopened.close()
        TestTemporaryDirectory.remove(fixture.directory)
    }

    func testRestoreIDConflictFailsWithoutOverwritingExistingRecord() throws {
        let fixture = try makeFixture(count: 1, timestamp: 65_000)
        defer { fixture.closeAndRemove() }
        let existing = try fixture.store.inspirationSynchronously(id: 1)

        XCTAssertThrowsError(
            try fixture.store.restoreInspirationSynchronously(existing)
        )
        XCTAssertEqual(
            try fixture.store.inspirationSynchronously(id: existing.id),
            existing
        )
    }

    func testStageFourOperationsFailAfterStoreCloses() throws {
        let fixture = try makeFixture(count: 1, timestamp: 66_000)
        let snapshot = try fixture.store.inspirationSynchronously(id: 1)
        fixture.store.close()
        defer { TestTemporaryDirectory.remove(fixture.directory) }

        let operations: [() throws -> Void] = [
            { _ = try fixture.store.listInspirationsPageSynchronously() },
            { _ = try fixture.store.inspirationSynchronously(id: 1) },
            {
                _ = try fixture.store.updateInspirationTextSynchronously(
                    id: 1,
                    title: "关闭后",
                    body: "不应写入",
                    updatedAtUTCms: 1
                )
            },
            {
                _ = try fixture.store.updateInspirationCategorySynchronously(
                    id: 1,
                    category: .article,
                    updatedAtUTCms: 1
                )
            },
            { _ = try fixture.store.deleteInspirationSynchronously(id: 1) },
            { _ = try fixture.store.restoreInspirationSynchronously(snapshot) }
        ]

        for operation in operations {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(error as? PersistenceError, .databaseClosed)
            }
        }
    }

    func testInvalidStoredCategoryIsRejectedDuringDecode() throws {
        let fixture = try makeFixture(count: 1, timestamp: 67_000)
        fixture.store.close()
        defer { TestTemporaryDirectory.remove(fixture.directory) }
        let connection = try SQLiteConnection(
            databaseURL: fixture.directory.appendingPathComponent(
                DataDirectoryResolver.databaseFileName
            )
        )
        try connection.execute(
            "PRAGMA ignore_check_constraints = ON",
            operation: "test_ignore_check_constraints"
        )
        try connection.execute(
            "UPDATE inspirations SET category = 'invalid' WHERE id = 1",
            operation: "test_corrupt_inspiration_category"
        )
        connection.close()
        let reopened = try JotBloomStore(dataDirectoryURL: fixture.directory)
        defer { reopened.close() }

        XCTAssertThrowsError(
            try reopened.listInspirationsPageSynchronously()
        ) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .invalidStoredValue(column: "inspirations.category")
            )
        }
    }

    func testMaximumTimestampCannotWrapDuringUpdate() throws {
        let fixture = try makeFixture(count: 1, timestamp: Int64.max)
        defer { fixture.closeAndRemove() }

        XCTAssertThrowsError(
            try fixture.store.updateInspirationTextSynchronously(
                id: 1,
                title: "不能回绕",
                body: "正文",
                updatedAtUTCms: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .invalidStoredValue(
                    column: "inspirations.updated_at_utc_ms"
                )
            )
        }
    }

    func testMissingRecordOperationsReportNotFound() throws {
        let fixture = try makeFixture(count: 0, timestamp: 70_000)
        defer { fixture.closeAndRemove() }

        let operations: [() throws -> Void] = [
            { _ = try fixture.store.inspirationSynchronously(id: 404) },
            {
                _ = try fixture.store.updateInspirationTextSynchronously(
                    id: 404,
                    title: "不存在",
                    body: "",
                    updatedAtUTCms: 1
                )
            },
            {
                _ = try fixture.store.updateInspirationCategorySynchronously(
                    id: 404,
                    category: .article,
                    updatedAtUTCms: 1
                )
            },
            { _ = try fixture.store.deleteInspirationSynchronously(id: 404) }
        ]

        for operation in operations {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(error as? PersistenceError, .inspirationNotFound(id: 404))
            }
        }
    }

    func testStageFourOperationsKeepSchemaAtVersionTwoWithoutBackup() throws {
        let fixture = try makeFixture(count: 2, timestamp: 80_000)
        defer { fixture.closeAndRemove() }

        _ = try fixture.store.listInspirationsPageSynchronously()
        _ = try fixture.store.updateInspirationTextSynchronously(
            id: 1,
            title: "仍是 V2",
            body: "正文",
            updatedAtUTCms: 80_001
        )

        XCTAssertEqual(try fixture.store.schemaVersionSynchronously(), 7)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.directory
                    .appendingPathComponent("jotbloom.sqlite.bak-v2")
                    .path
            )
        )
    }

    private func makeFixture(
        count: Int,
        timestamp: Int64
    ) throws -> InspirationStoreFixture {
        let directory = try TestTemporaryDirectory.make(
            prefix: "jotbloom-inspiration-store"
        )
        let store = try JotBloomStore(dataDirectoryURL: directory)
        for index in 0..<count {
            _ = try store.saveManualInspirationSynchronously(
                ParsedInspiration(
                    title: "标题 \(index)",
                    body: "正文 \(index)"
                ),
                timestampUTCms: timestamp
            )
        }
        return InspirationStoreFixture(directory: directory, store: store)
    }

    private func makeFixtureWithIncreasingTimestamps(
        count: Int
    ) throws -> InspirationStoreFixture {
        let directory = try TestTemporaryDirectory.make(
            prefix: "jotbloom-inspiration-cursor"
        )
        let store = try JotBloomStore(dataDirectoryURL: directory)
        for index in 0..<count {
            _ = try store.saveManualInspirationSynchronously(
                ParsedInspiration(
                    title: "标题 \(index)",
                    body: "正文 \(index)"
                ),
                timestampUTCms: Int64(index + 1)
            )
        }
        return InspirationStoreFixture(directory: directory, store: store)
    }
}

private struct InspirationStoreFixture {
    let directory: URL
    let store: JotBloomStore

    func closeAndRemove() {
        store.close()
        TestTemporaryDirectory.remove(directory)
    }
}
