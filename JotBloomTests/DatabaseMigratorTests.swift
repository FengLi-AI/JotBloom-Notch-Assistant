import Foundation
import XCTest
@testable import JotBloomCore

final class DatabaseMigratorTests: XCTestCase {
    func testBootstrapCreatesVersionTwoObjects() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let databaseURL = directory.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        defer { connection.close() }

        try DatabaseMigrator.bootstrap(connection)

        XCTAssertEqual(try connection.userVersion(), 7)
        let statement = try connection.prepare(
            """
            SELECT type, name
            FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """,
            operation: "test_list_schema"
        )
        var objects: [String] = []
        while try statement.stepRow() {
            objects.append("\(statement.text(at: 0)):\(statement.text(at: 1))")
        }
        XCTAssertEqual(
            objects,
            [
                "index:chat_message_order",
                "index:chat_session_order",
                "index:idx_clipboard_items_copied_at",
                "index:idx_clipboard_items_image_dedupe",
                "index:idx_inspirations_clipboard",
                "index:idx_inspirations_updated_at",
                "index:idx_prompts_created_at",
                "index:inspiration_category_order",
                "index:inspirations_manual_order",
                "index:prompts_manual_order",
                "table:chat_messages",
                "table:chat_sessions",
                "table:clipboard_items",
                "table:drafts",
                "table:inspirations",
                "table:prompts",
                "trigger:inspiration_lifecycle",
                "trigger:prompt_delete_flag",
                "trigger:prompt_insert_flag"
            ]
        )
    }

    func testHigherSchemaVersionIsRejectedWithoutMigration() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let databaseURL = directory.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try connection.setUserVersion(8)
        connection.close()

        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: directory)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
        .unsupportedSchema(found: 8, supported: 7)
            )
        }
    }

    func testVersionOneMissingRequiredObjectsIsRejected() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let databaseURL = directory.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try connection.setUserVersion(1)
        connection.close()

        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: directory)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .invalidSchema(object: "inspirations")
            )
        }
    }

    func testVersionTwoMissingClipboardIndexIsRejected() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let databaseURL = directory.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try DatabaseMigrator.bootstrap(connection)
        try connection.execute(
            "DROP INDEX idx_clipboard_items_image_dedupe",
            operation: "test_drop_clipboard_index"
        )
        connection.close()

        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: directory)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .invalidSchema(object: "idx_clipboard_items_image_dedupe")
            )
        }
    }

    func testCorruptDatabaseIsReportedWithoutReplacingIt() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let databaseURL = directory.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let original = Data("not a sqlite database".utf8)
        try original.write(to: databaseURL)

        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: directory)) { error in
            guard case .corruptedDatabase = error as? PersistenceError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    func testMigrationBackupNeverOverwritesExistingBackup() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let databaseURL = directory.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try DatabaseMigrator.createVersionOne(connection)
        connection.close()

        let backupURL = try DatabaseMigrator.createMigrationBackup(
            databaseURL: databaseURL,
            oldVersion: 1
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertThrowsError(
            try DatabaseMigrator.createMigrationBackup(
                databaseURL: databaseURL,
                oldVersion: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .backupAlreadyExists(path: backupURL.path)
            )
        }
    }

    func testVersionOneMigrationPreservesDataAndCreatesPrivateBackup() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let databaseURL = directory.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try DatabaseMigrator.createVersionOne(connection)
        try connection.execute(
            """
            INSERT INTO inspirations(
                title, body, category, category_source,
                created_at_utc_ms, updated_at_utc_ms, source
            ) VALUES ('迁移标题', '迁移正文', 'idea', 'fallback', 10, 11, 'manual')
            """,
            operation: "test_insert_v1_inspiration"
        )
        try connection.execute(
            """
            INSERT INTO drafts(kind, content, updated_at_utc_ms)
            VALUES ('inspiration', '迁移草稿', 12)
            """,
            operation: "test_insert_v1_draft"
        )
        connection.close()

        let store = try JotBloomStore(dataDirectoryURL: directory)
        XCTAssertEqual(try store.schemaVersionSynchronously(), 7)
        XCTAssertEqual(
            try store.listRecentInspirationsSynchronously().first?.body,
            "迁移标题\n迁移正文"
        )
        XCTAssertEqual(
            try store.loadDraftSynchronously(kind: .inspiration)?.content,
            "迁移草稿"
        )
        store.close()

        let backupURL = directory.appendingPathComponent(
            "\(DataDirectoryResolver.databaseFileName).bak-v1"
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: backupURL.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        let backup = try SQLiteConnection(databaseURL: backupURL)
        defer { backup.close() }
        XCTAssertEqual(try backup.userVersion(), 1)
        XCTAssertFalse(
            try backup.objectExists(type: "table", name: "clipboard_items")
        )
    }

    func testExistingBackupPreventsMigrationWithoutOverwritingEitherFile() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let databaseURL = directory.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try DatabaseMigrator.createVersionOne(connection)
        connection.close()
        let backupURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("\(databaseURL.lastPathComponent).bak-v1")
        let sentinel = Data("existing-backup".utf8)
        try sentinel.write(to: backupURL)

        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: directory)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .backupAlreadyExists(path: backupURL.path)
            )
        }
        let original = try SQLiteConnection(databaseURL: databaseURL)
        defer { original.close() }
        XCTAssertEqual(try original.userVersion(), 1)
        XCTAssertEqual(try Data(contentsOf: backupURL), sentinel)
    }

    func testFailedVersionOneMigrationKeepsOriginalAtVersionOneAndBackup() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let databaseURL = directory.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try DatabaseMigrator.createVersionOne(connection)
        try connection.execute(
            "CREATE TABLE idx_clipboard_items_copied_at (unexpected TEXT)",
            operation: "test_create_conflicting_index_name"
        )
        connection.close()

        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: directory))

        let reopened = try SQLiteConnection(databaseURL: databaseURL)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.userVersion(), 1)
        XCTAssertFalse(
            try reopened.objectExists(type: "table", name: "clipboard_items")
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: databaseURL.path + ".bak-v1"
            )
        )
    }

    func testDiagnosticsExposeCodesWithoutPathsOrBoundValues() {
        XCTAssertEqual(
            PersistenceDiagnostics.metadata(
                for: PersistenceError.sqliteFailure(
                    operation: "insert_private_value",
                    code: 19
                )
            ),
            PersistenceFailureMetadata(
                kind: "sqlite_failure",
                sqliteResultCode: 19,
                foundSchemaVersion: nil
            )
        )
        XCTAssertEqual(
            PersistenceDiagnostics.metadata(
                for: PersistenceError.unsupportedSchema(found: 8, supported: 2)
            ),
            PersistenceFailureMetadata(
                kind: "unsupported_schema",
                sqliteResultCode: nil,
                foundSchemaVersion: 8
            )
        )
    }
}
