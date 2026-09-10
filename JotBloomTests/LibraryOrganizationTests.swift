import Foundation
import XCTest
@testable import JotBloomCore

@MainActor
final class LibraryOrganizationTests: XCTestCase {
    private func settle(_ model: PromptLibraryViewModel) async throws {
        for _ in 0..<300 {
            if !model.busy && !model.isLoading { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("prompt model did not settle")
    }
    func testSaveAsFromFavoritesProvidesExplicitRevealAndKeepsOriginal() async throws {
        let id = try await prompt("原提示词正文")
        try await store.setPromptFavorite(id: id, favorite: true)
        let writer = TenBTestWriter()
        let model = PromptLibraryViewModel(store: store, writer: writer)
        model.favoritesOnly = true; try await settle(model)
        model.openEditor(id); try await settle(model)
        model.detailContent = "另存后的正文"
        model.saveDetail(asNew: true); try await settle(model)
        let copy = try XCTUnwrap(model.savedCopyID)
        XCTAssertNotEqual(copy, id)
        XCTAssertTrue(model.favoritesOnly)
        XCTAssertEqual(try store.promptSynchronously(id: id)?.content, "原提示词正文")
        XCTAssertFalse(try XCTUnwrap(store.promptSynchronously(id: copy)).isFavorite)
        XCTAssertEqual(model.detailID, copy)
        model.viewSavedCopy(); try await settle(model)
        XCTAssertFalse(model.favoritesOnly); XCTAssertNil(model.detailID)
        XCTAssertEqual(model.selectedID, copy); XCTAssertTrue(model.items.contains { $0.id == copy })
        XCTAssertGreaterThan(model.listRevealRequest, 0)
        XCTAssertTrue(writer.texts.isEmpty)
    }
    func testRevealProtectsNewUnsavedEditsAndCanFindCopyBeyondFirstPage() async throws {
        let id = try await prompt("初始正文")
        let model = PromptLibraryViewModel(store: store, writer: TenBTestWriter())
        model.openEditor(id); try await settle(model)
        model.saveDetail(asNew: true); try await settle(model)
        let copy = try XCTUnwrap(model.savedCopyID)
        model.detailContent = "另存后又输入的内容"
        model.viewSavedCopy()
        XCTAssertEqual(model.detailID, copy); XCTAssertTrue(model.hasUnsavedDetail)
        XCTAssertEqual(model.detailContent, "另存后又输入的内容")
        XCTAssertTrue(model.closeEditor(discard: true))
        for n in 0..<55 { _ = try await prompt("后来的提示词\(n)") }
        model.viewSavedCopy(); try await settle(model)
        XCTAssertEqual(model.selectedID, copy)
        XCTAssertTrue(model.items.contains { $0.id == copy })
    }
    func testInvalidPromptSaveAndCopyFailureKeepEditor() async throws {
        let id = try await prompt("数据库中的原正文"), writer = TenBTestWriter()
        let model = PromptLibraryViewModel(store: store, writer: writer)
        model.openEditor(id); try await settle(model)
        model.detailTitle = " "; model.detailContent = "还没保存的正文"
        model.saveDetail(); try await settle(model)
        XCTAssertTrue(model.hasUnsavedDetail); XCTAssertEqual(model.detailID, id)
        XCTAssertEqual(try store.promptSynchronously(id: id)?.content, "数据库中的原正文")
        XCTAssertFalse(model.closeEditor())
        writer.fails = true; model.copyDetail()
        XCTAssertTrue(model.feedback?.contains("复制失败") == true)
        XCTAssertEqual(model.detailContent, "还没保存的正文")
        writer.fails = false; model.copyDetail()
        XCTAssertEqual(writer.texts, ["还没保存的正文"])
        XCTAssertTrue(model.hasUnsavedDetail)
    }
    func testClearSnapshotKeepsNewAndRecapturedRecordsAndSavedCopies() async throws {
        let service = ClipboardService(store: store, assetStore: try ClipboardAssetStore(dataDirectoryURL: directory))
        let source = ClipboardSourceApplication(name: "Fixture", bundleIdentifier: "fixture")
        for text in ["需要清理", "重新采集"] {
            _ = try await service.capture(.init(content: .text(text), copiedAtUTCms: 1, sourceApplication: source))
        }
        let original = try XCTUnwrap(store.listClipboardItemsSynchronously().first { $0.textContent == "需要清理" })
        let saved = try await store.saveClipboard(id: original.id, to: .prompt, timestamp: 1)
        let snapshot = try store.listClipboardItemsSynchronously()
        _ = try await service.capture(.init(content: .text("新内容"), copiedAtUTCms: 2, sourceApplication: source))
        _ = try await service.capture(.init(content: .text("重新采集"), copiedAtUTCms: 3, sourceApplication: source))
        let success = try await service.clearHistory(snapshot: snapshot)
        XCTAssertTrue(success)
        XCTAssertEqual(Set(try store.listClipboardItemsSynchronously().compactMap(\.textContent)), Set(["新内容", "重新采集"]))
        XCTAssertEqual(try store.promptSynchronously(id: saved.id)?.content, "需要清理")
        XCTAssertNil(try store.promptSynchronously(id: saved.id)?.sourceClipboardID)
    }
    func testClearConfirmationCancelAndSnapshotAreStable() async throws {
        let service = ClipboardService(store: store, assetStore: try ClipboardAssetStore(dataDirectoryURL: directory))
        _ = try await service.capture(.init(content: .text("确认前"), copiedAtUTCms: 1, sourceApplication: .init(name: nil, bundleIdentifier: nil)))
        let model = ClipboardHistoryViewModel(service: service, pasteboardWriter: TenBTestWriter())
        model.start()
        for _ in 0..<200 where !model.isReady { try await Task.sleep(nanoseconds: 5_000_000) }
        var received: [ClipboardItem] = []
        model.onClearHistory = { snapshot in received = snapshot; return true }
        model.confirmingClear = true
        XCTAssertTrue(model.clearConfirmationMessage.contains("1 条"))
        model.confirmingClear = false; model.clearConfirmed()
        XCTAssertTrue(received.isEmpty)
        model.confirmingClear = true
        let later = try await service.capture(.init(content: .text("确认后"), copiedAtUTCms: 2, sourceApplication: .init(name: nil, bundleIdentifier: nil)))
        model.handleCaptureOutcome(later)
        model.clearConfirmed()
        for _ in 0..<200 where model.isClearing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(received.compactMap(\.textContent), ["确认前"])
        await model.prepareForTermination()
    }
    private var directory: URL!
    private var store: JotBloomStore!
    override func setUp() async throws {
        directory = try TestTemporaryDirectory.make()
        store = try JotBloomStore(dataDirectoryURL: directory)
    }
    override func tearDown() async throws {
        store.close(); TestTemporaryDirectory.remove(directory)
    }
    private func prompt(_ text: String, time: Int64 = 100) async throws -> Int64 {
        try await store.saveInputPrompt(content: text, token: UUID().uuidString, timestamp: time).id
    }
    private func inspiration(_ text: String, time: Int64 = 100) throws -> Inspiration {
        try store.saveManualInspirationSynchronously(XCTUnwrap(InspirationTextParser.parse(text)), timestampUTCms: time)
    }
    func testPromptOrderAndFavoriteSurviveReopenWithoutChangingSavedTime() async throws {
        let a = try await prompt("A"), b = try await prompt("B"), c = try await prompt("C")
        try await store.setPromptFavorite(id: a, favorite: true)
        try await store.reorderLibrary(.prompts, id: a, relativeTo: c)
        store.close(); store = try JotBloomStore(dataDirectoryURL: directory)
        let rows = try await store.listPrompts()
        XCTAssertEqual(rows.map(\.id), [a,c,b])
        XCTAssertTrue(rows[0].isFavorite)
        XCTAssertEqual(rows[0].createdAtUTCms, 100)
        let favorites = try await store.listPrompts(favoritesOnly: true)
        XCTAssertEqual(favorites.map(\.id), [a])
    }
    func testFavoriteReorderPreservesHiddenRowsAndNewSaveGoesFirst() async throws {
        let a = try await prompt("A"), b = try await prompt("B"), c = try await prompt("C")
        try await store.setPromptFavorite(id: a, favorite: true)
        try await store.setPromptFavorite(id: c, favorite: true)
        try await store.reorderLibrary(.prompts, id: a, relativeTo: c)
        let d = try await prompt("D", time: 1)
        let rows = try await store.listPrompts()
        XCTAssertEqual(rows.map(\.id), [d,a,c,b])
        try await store.setPromptFavorite(id: a, favorite: false)
        let favorites = try await store.listPrompts(favoritesOnly: true)
        XCTAssertEqual(favorites.map(\.id), [c])
    }
    func testPromptPaginationFollowsManualOrder() async throws {
        let a = try await prompt("A"), b = try await prompt("B"), c = try await prompt("C")
        try await store.reorderLibrary(.prompts, id: a, relativeTo: c)
        let first = try await store.listPrompts(limit: 2)
        let rest = try await store.listPrompts(after: first.last, limit: 2)
        XCTAssertEqual((first + rest).map(\.id), [a,c,b])
    }
    func testInspirationOrderPaginationAndRestoreKeepRank() async throws {
        let a = try inspiration("A"), b = try inspiration("B"), c = try inspiration("C")
        XCTAssertGreaterThan(a.sortOrder, 0)
        try await store.reorderLibrary(.inspirations, id: a.id, relativeTo: c.id)
        let first = try store.listInspirationsPageSynchronously(after: nil, limit: 2)
        let next = try store.listInspirationsPageSynchronously(after: first.nextCursor, limit: 2)
        XCTAssertEqual((first.items + next.items).map(\.id), [a.id,c.id,b.id])
        let deleted = try store.deleteInspirationSynchronously(id: c.id)
        _ = try store.restoreInspirationSynchronously(deleted)
        let rows = try store.listInspirationsPageSynchronously(after: nil, limit: 50)
        XCTAssertEqual(rows.items.map(\.id), [a.id,c.id,b.id])
        XCTAssertEqual(rows.items[0].createdAtUTCms, 100)
    }
    func testClearClipboardKeepsSavedTargetsAndFavorite() async throws {
        _ = try store.upsertClipboardTextSynchronously(text: "保留独立副本", contentType: .text, copiedAtUTCms: 1,
            sourceApplication: .init(name: "Fixture", bundleIdentifier: "fixture"))
        let source = try XCTUnwrap(store.listClipboardItemsSynchronously().first)
        let p = try await store.saveClipboard(id: source.id, to: .prompt, timestamp: 2)
        let i = try await store.saveClipboard(id: source.id, to: .inspiration, timestamp: 2)
        try await store.setPromptFavorite(id: p.id, favorite: true)
        let service = ClipboardService(store: store, assetStore: try ClipboardAssetStore(dataDirectoryURL: directory))
        let cleared = try await service.clearHistory()
        XCTAssertTrue(cleared)
        XCTAssertTrue(try store.listClipboardItemsSynchronously().isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.promptSynchronously(id: p.id)).isFavorite)
        XCTAssertEqual(try store.inspirationSynchronously(id: i.id).body, source.textContent)
    }
    func testClearInputCanUndoAndNewTypingInvalidatesUndo() async throws {
        let model = InspirationInputViewModel(store: store)
        model.start()
        for _ in 0..<100 where !model.isReady { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.isReady)
        model.text = "完整草稿\n第二行"
        model.clearInput()
        XCTAssertTrue(model.text.isEmpty); XCTAssertTrue(model.canUndoClear)
        model.undoClear(); XCTAssertEqual(model.text, "完整草稿\n第二行")
        model.clearInput(); model.text = "新内容"
        XCTAssertFalse(model.canUndoClear)
        model.undoClear(); XCTAssertEqual(model.text, "新内容")
        try model.flushDraftSynchronously()
    }
    func testV3UpgradeBacksUpAndPreservesRows() throws {
        let fixture = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(fixture) }
        let url = fixture.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let old = try SQLiteConnection(databaseURL: url)
        try DatabaseMigrator.createVersionTwo(old)
        try DatabaseMigrator.migrateVersionTwoToThree(old)
        try old.execute("INSERT INTO inspirations(title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source) VALUES ('原始记录','不能丢失','idea','fallback',100,200,'manual')", operation: "seed_v3")
        old.close()
        let upgraded = try JotBloomStore(dataDirectoryURL: fixture)
        defer { upgraded.close() }
        XCTAssertEqual(try upgraded.schemaVersionSynchronously(), 7)
        let record = try XCTUnwrap(upgraded.listInspirationsPageSynchronously(after: nil, limit: 10).items.first)
        XCTAssertEqual(record.body, "原始记录\n不能丢失"); XCTAssertEqual(record.sortOrder, 100)
        let backup = try SQLiteConnection(databaseURL: URL(fileURLWithPath: url.path + ".bak-v3"), readOnly: true, createIfMissing: false)
        defer { backup.close() }
        XCTAssertEqual(try backup.userVersion(), 3)
    }
    func testSavedTimeUsesLocalMonthDayAndMinute() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 4, minute: 44, second: 39)))
        XCTAssertEqual(SavedTime.text(Int64(date.timeIntervalSince1970 * 1000)), "9月6日 04:44")
    }
}

@MainActor
private final class TenBTestWriter: ClipboardWriting {
    var texts: [String] = []
    var fails = false
    func writeText(_ text: String) throws -> Int {
        if fails { throw ClipboardWriteError.writeFailed }
        texts.append(text); return texts.count
    }
    func writePNGData(_ data: Data) throws -> Int { throw ClipboardWriteError.writeFailed }
}
