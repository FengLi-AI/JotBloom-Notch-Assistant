import Foundation
import XCTest
@testable import JotBloomCore

final class JotBloomStoreTests: XCTestCase {
    func testTemporaryStoreLeavesProductionDatabaseSnapshotUnchanged() throws {
        let productionDatabase = try DataDirectoryResolver.productionDirectory()
            .appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let before = TestFileSnapshot.capture(productionDatabase)
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }

        let store = try JotBloomStore(dataDirectoryURL: directory)
        try store.persistDraftSynchronously(
            kind: .inspiration,
            content: "仅写入临时数据库",
            updatedAtUTCms: 1
        )
        store.close()

        XCTAssertEqual(TestFileSnapshot.capture(productionDatabase), before)
    }

    func testNewStoreCreatesVersionTwoDatabaseAndClipboardDirectory() throws {
        let root = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(root) }
        let directory = root.appendingPathComponent("data", isDirectory: true)

        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersionSynchronously(), 7)
        XCTAssertEqual(store.dataDirectoryURL, directory.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Clipboard").path
            )
        )
    }

    func testFileCannotBeUsedAsDataDirectory() throws {
        let root = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(root) }
        let fileURL = root.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: fileURL)

        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: fileURL)) { error in
            guard case .dataDirectoryUnavailable = error as? PersistenceError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDraftRoundTripsAcrossReopenIncludingUnicodeAndNullByte() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let content = "引号' 百分号% 🌱\n第二行\0结尾"

        var store: JotBloomStore? = try JotBloomStore(dataDirectoryURL: directory)
        try store?.persistDraftSynchronously(
            kind: .inspiration,
            content: content,
            updatedAtUTCms: 1_700_000_000_123
        )
        store?.close()
        store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store?.close() }

        let draft = try store?.loadDraftSynchronously(kind: .inspiration)
        XCTAssertEqual(draft?.kind, .inspiration)
        XCTAssertEqual(draft?.content, content)
        XCTAssertEqual(draft?.updatedAtUTCms, 1_700_000_000_123)
    }

    func testEmptyDraftContentDeletesDraft() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        try store.persistDraftSynchronously(
            kind: .inspiration,
            content: "尚未保存",
            updatedAtUTCms: 10
        )

        try store.persistDraftSynchronously(
            kind: .inspiration,
            content: "",
            updatedAtUTCms: 11
        )

        XCTAssertNil(try store.loadDraftSynchronously(kind: .inspiration))
    }

    func testManualSaveUsesFallbackMetadataAndAtomicallyClearsDraft() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        try store.persistDraftSynchronously(
            kind: .inspiration,
            content: "标题\n正文",
            updatedAtUTCms: 20
        )

        let saved = try store.saveManualInspirationSynchronously(
            ParsedInspiration(title: "标题", body: "正文"),
            timestampUTCms: 21
        )

        XCTAssertEqual(saved.title, "标题")
        XCTAssertEqual(saved.body, "标题\n正文")
        XCTAssertEqual(saved.category, .idea)
        XCTAssertEqual(saved.categorySource, .fallback)
        XCTAssertEqual(saved.source, .manual)
        XCTAssertEqual(saved.createdAtUTCms, 21)
        XCTAssertEqual(saved.updatedAtUTCms, 21)
        XCTAssertNil(try store.loadDraftSynchronously(kind: .inspiration))
        XCTAssertEqual(try store.listRecentInspirationsSynchronously(), [saved])
    }

    func testFailedDraftClearRollsBackInspirationInsert() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        var store: JotBloomStore? = try JotBloomStore(dataDirectoryURL: directory)
        try store?.persistDraftSynchronously(
            kind: .inspiration,
            content: "必须保留的草稿",
            updatedAtUTCms: 30
        )
        store?.close()

        let connection = try SQLiteConnection(
            databaseURL: directory.appendingPathComponent(
                DataDirectoryResolver.databaseFileName
            )
        )
        try connection.execute(
            """
            CREATE TRIGGER prevent_draft_clear
            BEFORE DELETE ON drafts
            BEGIN
                SELECT RAISE(ABORT, 'test rollback');
            END
            """,
            operation: "test_create_failure_trigger"
        )
        connection.close()

        store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store?.close() }
        XCTAssertThrowsError(
            try store?.saveManualInspirationSynchronously(
                ParsedInspiration(title: "不能半存", body: "正文"),
                timestampUTCms: 31
            )
        )
        XCTAssertEqual(
            try store?.loadDraftSynchronously(kind: .inspiration)?.content,
            "必须保留的草稿"
        )
        XCTAssertEqual(try store?.listRecentInspirationsSynchronously(), [])
    }

    func testRecentListIsStableNewestFirstAndCappedWithoutDeletingHistory() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)

        for index in 0...50 {
            _ = try store.saveManualInspirationSynchronously(
                ParsedInspiration(title: "标题 \(index)", body: "正文 \(index)"),
                timestampUTCms: 100
            )
        }
        let recent = try store.listRecentInspirationsSynchronously(limit: 100)
        store.close()

        XCTAssertEqual(recent.count, JotBloomStore.recentInspirationLimit)
        XCTAssertEqual(recent.first?.title, "标题 50")
        XCTAssertEqual(recent.last?.title, "标题 1")

        let connection = try SQLiteConnection(
            databaseURL: directory.appendingPathComponent(
                DataDirectoryResolver.databaseFileName
            )
        )
        defer { connection.close() }
        let statement = try connection.prepare(
            "SELECT COUNT(*) FROM inspirations",
            operation: "test_count_inspirations"
        )
        XCTAssertTrue(try statement.stepRow())
        XCTAssertEqual(statement.int64(at: 0), 51)
    }

    func testClosedStoreFailsWithoutReopeningImplicitly() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        store.close()

        XCTAssertThrowsError(try store.schemaVersionSynchronously()) { error in
            XCTAssertEqual(error as? PersistenceError, .databaseClosed)
        }
    }
}

private struct TestFileSnapshot: Equatable {
    let exists: Bool
    let size: UInt64?
    let modificationDate: Date?

    static func capture(_ url: URL) -> TestFileSnapshot {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: url.path
              ) else {
            return TestFileSnapshot(
                exists: false,
                size: nil,
                modificationDate: nil
            )
        }

        return TestFileSnapshot(
            exists: true,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }
}
