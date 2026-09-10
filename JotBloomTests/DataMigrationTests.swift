import Foundation
import XCTest
@testable import JotBloomCore

final class InitialDataDirectorySetupTests: XCTestCase {
    func testNewInstallInspectionDoesNotCreateDefaultStorage() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let control = root.appendingPathComponent("control")
        XCTAssertTrue(try InitialDataDirectorySetup().needsSelection(location: .init(controlDirectory: control)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
    }

    func testSelectionCreatesOnlySelectedBusinessDirectoryAndSurvivesRestart() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let control = root.appendingPathComponent("control"), parent = root.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let location = DataLocationStore(controlDirectory: control)
        let target = try InitialDataDirectorySetup().create(in: parent, location: location)
        XCTAssertEqual(target.lastPathComponent, "JotBloom")
        XCTAssertEqual(try location.activeDirectory(), target)
        XCTAssertFalse(try InitialDataDirectorySetup().needsSelection(location: location))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.appendingPathComponent("jotbloom.sqlite").path))
        let store = try JotBloomStore(dataDirectoryURL: target, requireExisting: true); defer { store.close() }
        XCTAssertEqual(try store.schemaVersionSynchronously(), 7)
        XCTAssertTrue(try store.listRecentInspirationsSynchronously().isEmpty)
    }

    func testExistingEmptyLegacyDatabaseIsNotFirstInstall() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        XCTAssertFalse(try InitialDataDirectorySetup().needsSelection(location: .init(controlDirectory: root)))
    }

    func testPreviouslyUsedMissingDatabaseRequiresRecovery() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        XCTAssertThrowsError(try InitialDataDirectorySetup().needsSelection(location: .init(controlDirectory: root.appendingPathComponent("missing")), previouslyUsed: true))
        try Data("incomplete".utf8).write(to: root.appendingPathComponent("jotbloom.sqlite-wal"))
        XCTAssertThrowsError(try InitialDataDirectorySetup().needsSelection(location: .init(controlDirectory: root)))
    }

    func testCorruptLocatorDoesNotStartNewSetup() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        try Data("broken".utf8).write(to: root.appendingPathComponent("data-location-v1.json"))
        XCTAssertThrowsError(try InitialDataDirectorySetup().needsSelection(location: .init(controlDirectory: root)))
    }

    func testExistingNamedDirectoryIsNeverOverwritten() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let target = root.appendingPathComponent("JotBloom")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let marker = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        XCTAssertThrowsError(try InitialDataDirectorySetup().create(in: root, location: .init(controlDirectory: root.appendingPathComponent("control"))))
        XCTAssertEqual(try String(contentsOf: marker), "keep")
    }

    func testFailureBeforeCommitDoesNotAdoptOrLeaveNewDatabase() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let location = DataLocationStore(controlDirectory: root.appendingPathComponent("control"))
        XCTAssertThrowsError(try InitialDataDirectorySetup().create(in: root, location: location, beforeCommit: { throw SettingsError.migrationFailed }))
        XCTAssertNil(try location.record())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("JotBloom").path))
        XCTAssertTrue(try InitialDataDirectorySetup().needsSelection(location: location))
    }

    func testMissingSelectedDirectoryNeverFallsBackToFirstInstall() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let location = DataLocationStore(controlDirectory: root.appendingPathComponent("control"))
        let target = try InitialDataDirectorySetup().create(in: root, location: location)
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("unavailable"))
        XCTAssertThrowsError(try InitialDataDirectorySetup().needsSelection(location: location))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}

final class DataMigrationTests: XCTestCase {
    func testWALImageDraftAndInspirationSurviveMigrationAndRestart() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let source = root.appendingPathComponent("source"), parent = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = try populatedStore(source); defer { store.close() }
        let location = DataLocationStore(controlDirectory: source)
        let target = try DataDirectoryMigration().migrate(store: store, parent: parent, location: location)
        XCTAssertEqual(try location.activeDirectory(), target)
        XCTAssertEqual(try location.migrationJournal()?.phase, .committed)
        let migrated = try JotBloomStore(dataDirectoryURL: target); defer { migrated.close() }
        XCTAssertEqual(try migrated.migrationRecordCounts(), try store.migrationRecordCounts())
        XCTAssertEqual(try migrated.loadDraftSynchronously(kind: .inspiration), try store.loadDraftSynchronously(kind: .inspiration))
        XCTAssertEqual(try migrated.listRecentInspirationsSynchronously(), try store.listRecentInspirationsSynchronously())
        let names = try store.referencedClipboardAssetFileNamesSynchronously()
        for name in names {
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Clipboard/" + name)), try Data(contentsOf: source.appendingPathComponent("Clipboard/" + name)))
        }
        _ = try migrated.saveManualInspirationSynchronously(XCTUnwrap(InspirationTextParser.parse("迁移后新内容")), timestampUTCms: 99)
        XCTAssertEqual(try migrated.listRecentInspirationsSynchronously().count, 2)
        XCTAssertEqual(try store.listRecentInspirationsSynchronously().count, 1)
        XCTAssertEqual(try DataLocationStore(controlDirectory: source).activeDirectory(), target)
    }
    func testEmptyDatabaseMigrationAndSamePathNoOp() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("JotBloom")); defer { store.close() }
        let location = DataLocationStore(controlDirectory: store.dataDirectoryURL)
        XCTAssertEqual(try DataDirectoryMigration().migrate(store: store, parent: root, location: location).path, store.dataDirectoryURL.path)
        XCTAssertNil(try location.record())
        let parent = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertNoThrow(try DataDirectoryMigration().migrate(store: store, parent: parent, location: location))
    }
    func testEachPrecommitFailurePreservesSourceAndPostcommitNeverReverts() throws {
        for phase: MigrationPhase in [.copying, .validating, .ready, .committed] {
            let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
            let source = root.appendingPathComponent("source"), parent = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let store = try populatedStore(source); defer { store.close() }
            let location = DataLocationStore(controlDirectory: source)
            let migration = DataDirectoryMigration { if $0 == phase { throw SettingsError.migrationFailed } }
            if phase == .committed {
                let target = try migration.migrate(store: store, parent: parent, location: location)
                XCTAssertEqual(try location.activeDirectory(), target)
            } else {
                XCTAssertThrowsError(try migration.migrate(store: store, parent: parent, location: location))
                XCTAssertEqual(try location.activeDirectory(), source)
            }
            XCTAssertEqual(try store.listRecentInspirationsSynchronously().count, 1)
            XCTAssertEqual(try store.listClipboardItemsSynchronously().count, 1)
        }
    }
    func testExistingTargetAndNestedDestinationAreRejected() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try populatedStore(root.appendingPathComponent("source")); defer { store.close() }
        let location = DataLocationStore(controlDirectory: store.dataDirectoryURL)
        let parent = root.appendingPathComponent("destination")
        let occupied = parent.appendingPathComponent("JotBloom")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: occupied.appendingPathComponent("user-file"))
        XCTAssertThrowsError(try DataDirectoryMigration().migrate(store: store, parent: parent, location: location))
        XCTAssertThrowsError(try DataDirectoryMigration().migrate(store: store, parent: store.dataDirectoryURL, location: location))
        XCTAssertEqual(try String(contentsOf: occupied.appendingPathComponent("user-file")), "keep")
    }
    func testMissingAssetAndExternalSymlinkCannotBeCopied() throws {
        for symlink in [false, true] {
            let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
            let store = try populatedStore(root.appendingPathComponent("source")); defer { store.close() }
            let parent = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let name = try XCTUnwrap(store.referencedClipboardAssetFileNamesSynchronously().first)
            let asset = store.clipboardDirectoryURL.appendingPathComponent(name)
            try FileManager.default.removeItem(at: asset)
            if symlink {
                let external = root.appendingPathComponent("external-secret")
                try Data("must-not-copy".utf8).write(to: external)
                try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: external)
            }
            XCTAssertThrowsError(try DataDirectoryMigration().migrate(store: store, parent: parent, location: DataLocationStore(controlDirectory: store.dataDirectoryURL)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("JotBloom").path))
        }
    }
    func testMissingVolumeNeverCreatesEmptyDatabaseAndIdentityAllowsRelocation() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let source = root.appendingPathComponent("source"), parent = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = try populatedStore(source); defer { store.close() }
        let location = DataLocationStore(controlDirectory: source)
        let target = try DataDirectoryMigration().migrate(store: store, parent: parent, location: location)
        let moved = root.appendingPathComponent("remounted")
        try FileManager.default.moveItem(at: target, to: moved)
        XCTAssertThrowsError(try location.activeDirectory())
        XCTAssertThrowsError(try location.relocate(to: source), "Retained old snapshot must not masquerade as the active library")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let unrelated = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("unrelated")); defer { unrelated.close() }
        XCTAssertThrowsError(try location.relocate(to: unrelated.dataDirectoryURL))
        try location.relocate(to: moved)
        XCTAssertEqual(try location.activeDirectory().path, moved.path)
    }
    func testMalformedLocatorDoesNotFallBack() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        try Data("broken".utf8).write(to: root.appendingPathComponent("data-location-v1.json"))
        XCTAssertThrowsError(try DataLocationStore(controlDirectory: root).activeDirectory())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("jotbloom.sqlite").path))
    }
    func testExistingOnlyStoreNeverCreatesMissingDatabase() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let missing = root.appendingPathComponent("missing-volume")
        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: missing, requireExisting: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: root, requireExisting: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("jotbloom.sqlite").path))
    }
    private func populatedStore(_ directory: URL) throws -> JotBloomStore {
        let store = try JotBloomStore(dataDirectoryURL: directory)
        _ = try store.saveManualInspirationSynchronously(XCTUnwrap(InspirationTextParser.parse("已有灵感\n正文")), timestampUTCms: 1)
        try store.persistDraftSynchronously(kind: .inspiration, content: "未提交草稿", updatedAtUTCms: 2)
        let assets = try ClipboardAssetStore(dataDirectoryURL: directory)
        let names = try assets.writeNewImage(pngData: Data([1, 2, 3]), thumbnailPNGData: Data([4, 5]))
        _ = try store.insertClipboardImageSynchronously(names: names, byteCount: 3, sha256: String(repeating: "a", count: 64), widthPixels: 1, heightPixels: 1, copiedAtUTCms: 3, sourceApplication: .init(name: "Fixture", bundleIdentifier: "test.fixture"))
        return store
    }
}
