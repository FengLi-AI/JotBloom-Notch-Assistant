import XCTest
@testable import JotBloomCore

@MainActor
final class FileShelfTests: XCTestCase {
    private func file(_ root: URL, _ name: String, content: String = "test") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
    func testOnlyReferencesPersistAndBulkRemovalNeverTouchesSources() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let original = try file(root, "original/方案.pdf", content: String(repeating: "large", count: 100_000))
        let store = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("app")); defer { store.close() }
        let model = FileShelfViewModel(store: store); await model.load()
        let accepted = await model.add([original]); XCTAssertTrue(accepted)
        let saved = try await store.loadFileShelf()
        XCTAssertEqual(saved.count, 1)
        XCTAssertLessThan(try JSONEncoder().encode(saved).count, 10_000)
        XCTAssertEqual(saved[0].kind, .document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.dataDirectoryURL.appendingPathComponent("方案.pdf").path))
        let reopened = FileShelfViewModel(store: store); await reopened.load()
        XCTAssertEqual(reopened.items, saved)
        reopened.selectAll(); await reopened.removeSelection()
        XCTAssertTrue(reopened.items.isEmpty); XCTAssertEqual(try String(contentsOf: original).count, 500_000)
        await reopened.undo(); XCTAssertEqual(reopened.items, saved)
        reopened.confirmingClear = false; await reopened.clearConfirmed(); XCTAssertEqual(reopened.items.count, 1)
        reopened.confirmingClear = true
        XCTAssertNil(reopened.filesForHandoff(Set(reopened.items.map(\.id))))
        await reopened.clearConfirmed()
        XCTAssertTrue(reopened.items.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testDuplicatesKeepIdentityDateAndUseRequestedPosition() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let a = try file(root, "one/same.txt"), b = try file(root, "two/same.txt"), c = try file(root, "last.txt")
        let store = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("app")); defer { store.close() }
        let model = FileShelfViewModel(store: store); await model.load()
        _ = await model.add([a,b,c]); let initial = model.items
        _ = await model.add([a,a], before: initial[2].id)
        XCTAssertEqual(model.items.map(\.id), [initial[1].id, initial[0].id, initial[2].id])
        XCTAssertEqual(model.items[1].addedAt, initial[0].addedAt)
        XCTAssertEqual(Set(model.items.map(\.identity)).count, 3)
    }
    func testCombinedFiltersSelectionAndHiddenOrder() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let urls = try ["a.png", "hidden.txt", "b.jpg", "c.png"].map { try file(root, $0) }
        let store = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("app")); defer { store.close() }
        let model = FileShelfViewModel(store: store); await model.load(); _ = await model.add(urls)
        let original = model.items
        model.kind = .image; model.date = .today
        XCTAssertEqual(model.visibleItems.count, 3)
        model.selectAll(); XCTAssertEqual(model.selection.count, 3)
        await model.move([original[3].id], before: original[0].id)
        XCTAssertEqual(model.items.map(\.id), [original[3].id, original[1].id, original[0].id, original[2].id])
        model.kind = .document
        XCTAssertTrue(model.selection.isEmpty); XCTAssertEqual(model.date, .today)
        model.date = .yesterday; XCTAssertTrue(model.visibleItems.isEmpty)
        model.resetFilters(); XCTAssertEqual(model.visibleItems.count, 4)
        let persisted = try await store.loadFileShelf(); XCTAssertEqual(persisted, model.items)
    }
    func testMissingBatchCannotHandoffPartialFilesAndContentUpdatesRemainLive() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let a = try file(root, "a.txt"), b = try file(root, "b.txt")
        let store = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("app")); defer { store.close() }
        let model = FileShelfViewModel(store: store); await model.load(); _ = await model.add([a,b])
        try Data("updated".utf8).write(to: a)
        let ids = Set(model.items.map(\.id))
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(model.filesForHandoff(ids)?[model.items[0].id])), "updated")
        try FileManager.default.removeItem(at: b)
        XCTAssertNil(model.filesForHandoff(ids)); XCTAssertEqual(model.items.count, 2)
        await model.refresh(); XCTAssertNotNil(model.problems[model.items[1].id])
    }
    func testReplacementDoesNotSilentlySendDifferentFile() throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let a = try file(root, "a.txt")
        let record = try FileReference.create(url: a)
        let moved = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: a, to: moved)
        _ = try file(root, "a.txt", content: "unrelated")
        // Bookmark recovery may follow a rename. A fallback may fail, but never return the replacement.
        if let result = try? record.resolved() { XCTAssertEqual(result.identity, record.identity); XCTAssertNotEqual(try String(contentsOf: result.url), "unrelated") }
    }
    func testPartialAddAndClosedStoreDoNotLoseExistingState() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let original = try file(root, "original.txt")
        let store = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("app"))
        let model = FileShelfViewModel(store: store); await model.load()
        let accepted = await model.add([original, root.appendingPathComponent("missing.txt")])
        XCTAssertFalse(accepted); XCTAssertEqual(model.items.count, 1)
        let previous = model.items; model.selectAll(); store.close()
        await model.removeSelection(); XCTAssertEqual(model.items, previous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testDataDirectoryMigrationCarriesReferencesNotOriginalFiles() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let original = try file(root, "originals/source.txt")
        let store = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("app")); defer { store.close() }
        let reference = try FileReference.create(url: original)
        try await store.saveFileShelf([reference])
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = try DataDirectoryMigration().migrate(store: store, parent: destination, location: .init(controlDirectory: root.appendingPathComponent("control")))
        let migrated = try JotBloomStore(dataDirectoryURL: target); defer { migrated.close() }
        let result = try await migrated.loadFileShelf(); XCTAssertEqual(result, [reference])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("source.txt").path))
    }
    func testLegacySearchPositionMigratesButDefaultSearchStillWorks() {
        let preferences = PanelPreferences(order: [.chat, .globalSearch, .clipboard, .inspiration, .prompts, .inspirationLibrary], defaultSlot: .globalSearch)
        XCTAssertEqual(preferences.order, [.chat, .fileShelf, .clipboard, .inspiration, .prompts, .inspirationLibrary])
        XCTAssertEqual(preferences.defaultSlot, .globalSearch)
        XCTAssertEqual(PanelPreferences(order: preferences.order).order, preferences.order)
    }
    func testTypeClassificationAndFolderDoNotInspectContents() throws {
        for (name, kind): (String, ShelfFileKind) in [("a.PNG", .image), ("a.pdf", .document), ("a.xlsx", .document), ("a.mp4", .video), ("a.mp3", .audio), ("a.7z", .archive), ("a.xyzunknown", .other)] {
            XCTAssertEqual(ShelfFileKind.classify(URL(fileURLWithPath: name), directory: false), kind)
        }
        XCTAssertEqual(ShelfFileKind.classify(URL(fileURLWithPath: "images.png"), directory: true), .folder)
    }
    func testVersionSevenUpgradePreservesExistingDraftAndCreatesEmptyShelf() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let dbURL = root.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let db = try SQLiteConnection(databaseURL: dbURL)
        try DatabaseMigrator.bootstrap(db)
        try db.execute("DROP TABLE file_shelf; PRAGMA user_version=7; INSERT INTO drafts(kind,content,updated_at_utc_ms) VALUES('inspiration','existing draft',1)", operation: "test_v7_fixture")
        db.close()
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let shelf = try await store.loadFileShelf()
        let draft = try await store.loadDraft(kind: .inspiration)
        XCTAssertTrue(shelf.isEmpty); XCTAssertEqual(draft?.content, "existing draft")
        let check = try SQLiteConnection(databaseURL: dbURL); defer { check.close() }
        XCTAssertEqual(try check.userVersion(), 8)
    }

    func testIndependentSettingDefaultsOnAndPersistsWithoutClipboardMonitoring() {
        let suite = "JotBloom.FileShelfTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["version": 1, "monitoringEnabled": false], forKey: "jotbloom.settings.v1")
        let store = AppSettingsStore(defaults: defaults)
        var value = store.load()
        XCTAssertTrue(value.fileShelfEnabled); XCTAssertFalse(value.monitoringEnabled)
        value.fileShelfEnabled = false; store.save(value)
        XCTAssertFalse(store.load().fileShelfEnabled); XCTAssertFalse(store.load().monitoringEnabled)
    }

    func testFilteredRemovalNeverDeletesHiddenSelectionAndClearIncludesHiddenReferences() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let image = try file(root, "a.png"), text = try file(root, "b.txt")
        let store = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("app")); defer { store.close() }
        let model = FileShelfViewModel(store: store); await model.load(); _ = await model.add([image, text])
        let initial = model.items
        model.kind = .image; model.selection = Set(initial.map(\.id))
        await model.removeSelection()
        XCTAssertEqual(model.items.map(\.id), [initial[1].id])
        await model.undo(); model.confirmingClear = true; await model.clearConfirmed()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: text.path))
    }

}
