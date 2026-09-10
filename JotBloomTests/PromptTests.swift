import Foundation
import XCTest
@testable import JotBloomCore

@MainActor
final class PromptTests: XCTestCase {
    private var directory: URL!
    private var store: JotBloomStore!
    override func setUp() async throws { directory = try TestTemporaryDirectory.make(); store = try JotBloomStore(dataDirectoryURL: directory) }
    override func tearDown() async throws { store.close(); TestTemporaryDirectory.remove(directory) }
    private func clipboard(_ text: String) throws -> Int64 {
        let outcome = try store.upsertClipboardTextSynchronously(text: text, contentType: .text, copiedAtUTCms: 1,
            sourceApplication: ClipboardSourceApplication(name: "Fixture", bundleIdentifier: "test.fixture"))
        switch outcome { case .inserted(let row), .refreshed(let row): return row.id; case .skipped: throw PromptError.sourceMissing }
    }
    private func input(_ text: String, token: String = UUID().uuidString, time: Int64 = 1) async throws -> Int64 {
        try await store.saveInputPrompt(content: text, token: token, timestamp: time).id
    }
    func testClipboardPromptRetainsFullOriginalAndSurvivesSourceDeletion() async throws {
        let text = "  第一行\n" + String(repeating: "内容🐈", count: 5000)
        let id = try clipboard(text)
        let saved = try await store.saveClipboard(id: id, to: .prompt, timestamp: 2)
        XCTAssertTrue(saved.created)
        XCTAssertTrue(try store.listClipboardItemsSynchronously()[0].isFavoritedToPrompt)
        _ = try store.deleteClipboardItemSynchronously(id: id)
        let row = try XCTUnwrap(store.promptSynchronously(id: saved.id))
        XCTAssertEqual(row.content, text); XCTAssertNil(row.sourceClipboardID); XCTAssertEqual(row.sourceApplicationName, "Fixture")
    }
    func testRepeatedSourceIsIdempotentAndDoesNotOverwriteManualTitle() async throws {
        let id = try clipboard("标题内容")
        let first = try await store.saveClipboard(id: id, to: .prompt, timestamp: 1)
        try store.renamePromptSynchronously(id: first.id, title: "人工标题")
        let second = try await store.saveClipboard(id: id, to: .prompt, timestamp: 999)
        XCTAssertFalse(second.created); XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(try store.promptSynchronously(id: first.id)?.title, "人工标题")
        XCTAssertEqual(try store.promptSynchronously(id: first.id)?.createdAtUTCms, 1)
    }
    func testClipboardInspirationKeepsLongFirstLineAndDraftUntouched() async throws {
        let text = "\n" + String(repeating: "长", count: 60) + "\n完整正文"
        let source = try clipboard(text)
        try store.persistDraftSynchronously(kind: .inspiration, content: "不能清掉草稿", updatedAtUTCms: 1)
        let saved = try await store.saveClipboard(id: source, to: .inspiration, timestamp: 2)
        let row = try store.inspirationSynchronously(id: saved.id)
        XCTAssertEqual(row.body, text); XCTAssertEqual(row.title.count, 30); XCTAssertEqual(row.source, .manual)
        XCTAssertEqual(row.originKind, "clipboard"); XCTAssertEqual(row.sourceClipboardID, source)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "不能清掉草稿")
        _ = try store.updateInspirationTextSynchronously(id: row.id, title: "编辑后", body: "人工正文", updatedAtUTCms: 3)
        let repeated = try await store.saveClipboard(id: source, to: .inspiration, timestamp: 4)
        XCTAssertFalse(repeated.created); XCTAssertEqual(try store.inspirationSynchronously(id: row.id).body, "人工正文")
    }
    func testDeleteReSaveAndUndoPreservesBothTargetsWithoutStealingSource() async throws {
        let source = try clipboard("目标独立保存")
        let saved = try await store.saveClipboard(id: source, to: .prompt, timestamp: 1)
        let deleted = try await store.deletePrompt(id: saved.id)
        XCTAssertFalse(try store.listClipboardItemsSynchronously()[0].isFavoritedToPrompt)
        let replacement = try await store.saveClipboard(id: source, to: .prompt, timestamp: 2)
        let associated = try await store.restorePrompt(deleted)
        XCTAssertFalse(associated)
        XCTAssertNil(try store.promptSynchronously(id: saved.id)?.sourceClipboardID)
        XCTAssertEqual(try store.promptSynchronously(id: replacement.id)?.sourceClipboardID, source)
        let restored = try XCTUnwrap(store.promptSynchronously(id: saved.id))
        XCTAssertNotEqual(restored.lifecycleToken, deleted.lifecycleToken)
        XCTAssertFalse(try store.applyPromptTitleSynchronously("迟到标题", expected: deleted))
    }
    func testSourceUndoDoesNotResurrectOldFavoriteFlag() async throws {
        let source = try clipboard("清理前保存")
        _ = try await store.saveClipboard(id: source, to: .prompt, timestamp: 1)
        let deleted = try XCTUnwrap(store.deleteClipboardItemSynchronously(id: source))
        let restored = try store.restoreClipboardItemSynchronously(deleted)
        XCTAssertFalse(restored.isFavoritedToPrompt)
    }
    func testInspirationUndoRestoresSourceMetadataAndHandlesOccupiedSource() async throws {
        let source = try clipboard("灵感来源")
        let saved = try await store.saveClipboard(id: source, to: .inspiration, timestamp: 1)
        let deleted = try store.deleteInspirationSynchronously(id: saved.id)
        let restored = try store.restoreInspirationSynchronously(deleted)
        XCTAssertEqual(restored.sourceClipboardID, source); XCTAssertEqual(restored.sourceApplicationName, "Fixture")
        _ = try store.deleteInspirationSynchronously(id: saved.id)
        _ = try await store.saveClipboard(id: source, to: .inspiration, timestamp: 2)
        let independent = try store.restoreInspirationSynchronously(deleted)
        XCTAssertNil(independent.sourceClipboardID); XCTAssertEqual(independent.body, deleted.body)
    }
    func testInputSubmissionIdempotenceIsNotBodyDeduplication() async throws {
        try store.persistDraftSynchronously(kind: .inspiration, content: "原文", updatedAtUTCms: 1)
        let first = try await input("原文", token: "submission")
        XCTAssertNil(try store.loadDraftSynchronously(kind: .inspiration))
        try store.persistDraftSynchronously(kind: .inspiration, content: "新草稿", updatedAtUTCms: 2)
        let repeated = try await input("原文", token: "submission")
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "新草稿")
        let new = try await input("原文"); XCTAssertNotEqual(new, first)
        XCTAssertTrue(try store.listRecentInspirationsSynchronously().isEmpty)
    }
    func testRejectedInputRetainsDraftAndCreatesNoRows() async throws {
        try store.persistDraftSynchronously(kind: .inspiration, content: "保留", updatedAtUTCms: 1)
        for text in [" \n", String(repeating: "a", count: 1_000_001)] {
            do { _ = try await input(text); XCTFail("must reject") } catch is PromptError { }
        }
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "保留")
        let rows = try await store.listPrompts(); XCTAssertTrue(rows.isEmpty)
    }
    func testMillionCharactersAndLiteralSearchFindsTailBeyondPreview() async throws {
        let text = String(repeating: "a", count: 999_994) + "结束🪷%_"
        let id = try await input(text)
        XCTAssertEqual(try store.promptSynchronously(id: id)?.content, text)
        XCTAssertEqual(try store.searchAllSynchronously(query: "结束🪷%_").prompts.map(\.id.recordID), [id])
    }
    func testMissingAndImageSourcesAreRejected() async throws {
        do { _ = try await store.saveClipboard(id: 999, to: .prompt, timestamp: 1); XCTFail() } catch is PromptError { }
        _ = try store.insertClipboardImageSynchronously(names: .init(imageFileName: "fixture.png", thumbnailFileName: "fixture-thumb.png"), byteCount: 1,
            sha256: String(repeating: "a", count: 64), widthPixels: 1, heightPixels: 1, copiedAtUTCms: 1, sourceApplication: .init(name: nil, bundleIdentifier: nil))
        let imageID = try store.listClipboardItemsSynchronously()[0].id
        for target in [SaveTarget.prompt, .inspiration] {
            do { _ = try await store.saveClipboard(id: imageID, to: target, timestamp: 1); XCTFail() } catch is PromptError { }
        }
        XCTAssertThrowsError(try PromptText.validate(" \n"))
    }
    func testConcurrentSourceSavesCreateOneTarget() async throws {
        let source = try clipboard("同一来源")
        async let a = store.saveClipboard(id: source, to: .prompt, timestamp: 1)
        async let b = store.saveClipboard(id: source, to: .prompt, timestamp: 2)
        let results = try await [a, b]
        XCTAssertEqual(results.filter(\.created).count, 1); XCTAssertEqual(results[0].id, results[1].id)
    }
    func testTransactionFailureDoesNotConsumeDraftOrLeavePrompt() async throws {
        try store.persistDraftSynchronously(kind: .inspiration, content: "保留草稿", updatedAtUTCms: 1)
        try store.performSync { try $0.execute("CREATE TRIGGER fail_clear BEFORE DELETE ON drafts BEGIN SELECT RAISE(ABORT, 'fixture'); END", operation: "fixture_fail") }
        do { _ = try await input("保留草稿"); XCTFail() } catch { }
        let rows = try await store.listPrompts(); XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "保留草稿")
    }
    func testV3MigrationFailureRollsBackSchemaAndRetainsV2Backup() throws {
        let oldDir = directory.appendingPathComponent("failed-upgrade")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let url = oldDir.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let old = try SQLiteConnection(databaseURL: url)
        try DatabaseMigrator.createVersionTwo(old)
        // Deliberate conflicting object, before the ALTER sequence can commit.
        try old.execute("CREATE TABLE prompts (fixture TEXT)", operation: "fixture_conflict")
        old.close()
        XCTAssertThrowsError(try JotBloomStore(dataDirectoryURL: oldDir))
        let after = try SQLiteConnection(databaseURL: url)
        defer { after.close() }
        XCTAssertEqual(try after.userVersion(), 2)
        XCTAssertFalse(try after.objectExists(type: "index", name: "idx_prompts_created_at"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak-v2").path))
    }
    func testThreeSourceSearchOrderingAndSameIDsAreDistinct() async throws {
        let source = try clipboard("共同内容")
        let p = try await store.saveClipboard(id: source, to: .prompt, timestamp: 1)
        _ = try await store.saveClipboard(id: source, to: .inspiration, timestamp: 1)
        let results = try store.searchAllSynchronously(query: "共同")
        XCTAssertEqual(results.allResults.map(\.source), [.clipboard, .prompt, .inspiration])
        XCTAssertEqual(Set(results.allResults.map(\.id)).count, 3)
        XCTAssertEqual(results.prompts.first?.id.recordID, p.id)
    }
    func testPagingIsStableAndRenameDoesNotReorder() async throws {
        for n in 0..<56 { _ = try await input("分页\(n)", time: 1) }
        let first = try await store.listPrompts()
        let second = try await store.listPrompts(after: first.last)
        XCTAssertEqual(first.count, 50); XCTAssertEqual(second.count, 6)
        XCTAssertEqual(Set((first + second).map(\.id)).count, 56)
        try store.renamePromptSynchronously(id: second[0].id, title: "新标题")
        let reloaded = try await store.listPrompts(); XCTAssertEqual(reloaded.map(\.id), first.map(\.id))
    }
    func testManualTitleBlocksAIAndEmptyTitleDoesNotCommit() async throws {
        let id = try await input("自动标题原文")
        let before = try XCTUnwrap(store.promptSynchronously(id: id))
        XCTAssertThrowsError(try store.renamePromptSynchronously(id: id, title: " \n"))
        try store.renamePromptSynchronously(id: id, title: before.title)
        XCTAssertFalse(try store.applyPromptTitleSynchronously("自动标题", expected: before))
        XCTAssertEqual(try store.promptSynchronously(id: id)?.titleSource, .user)
    }
    func testAICompareAndSwapAcceptsOnlyOneResult() async throws {
        let id = try await input("自动标题原文")
        let before = try XCTUnwrap(store.promptSynchronously(id: id))
        XCTAssertTrue(try store.applyPromptTitleSynchronously("用途说明标题", expected: before))
        XCTAssertFalse(try store.applyPromptTitleSynchronously("第二次旧结果", expected: before))
    }
    func testDraftABADuringPromptSaveIsRetained() async throws {
        let model = InspirationInputViewModel(store: store, debounceNanoseconds: 1_000_000)
        model.savePrompt = { [store = store!] text, token, timestamp in
            try await Task.sleep(nanoseconds: 30_000_000)
            return try await store.saveInputPrompt(content: text, token: token, timestamp: timestamp)
        }
        model.start()
        for _ in 0..<100 { if model.isReady { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        model.text = "A"; model.saveToPrompt(); model.text = "B"; model.text = "A"
        model.save(); model.saveToPrompt()
        await model.waitForPendingSave()
        try model.flushDraftSynchronously()
        XCTAssertEqual(model.text, "A")
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "A")
        let rows = try await store.listPrompts(); XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(try store.listRecentInspirationsSynchronously().isEmpty)
    }
    func testV2WALUpgradeBackupIncludesCommittedData() throws {
        store.close()
        let oldDir = directory.appendingPathComponent("v2")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let url = oldDir.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let old = try SQLiteConnection(databaseURL: url)
        defer { old.close() }
        try DatabaseMigrator.createVersionTwo(old)
        try old.execute("PRAGMA journal_mode=WAL; INSERT INTO drafts(kind,content,updated_at_utc_ms) VALUES ('inspiration','WAL草稿',1)", operation: "fixture_wal")
        let upgraded = try JotBloomStore(dataDirectoryURL: oldDir)
        defer { upgraded.close() }
        XCTAssertEqual(try upgraded.schemaVersionSynchronously(), 7)
        let backup = try SQLiteConnection(databaseURL: url.appendingPathExtension("bak-v2"), readOnly: true)
        defer { backup.close() }
        XCTAssertEqual(try backup.userVersion(), 2)
        let query = try backup.prepare("SELECT content FROM drafts", operation: "read_backup")
        XCTAssertTrue(try query.stepRow()); XCTAssertEqual(query.text(at: 0), "WAL草稿")
    }
    func testV3MigrationCarriesPromptsAndSourceRelations() async throws {
        let source = try clipboard("搬迁原文")
        let saved = try await store.saveClipboard(id: source, to: .prompt, timestamp: 1)
        let parent = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(parent) }
        let location = DataLocationStore(controlDirectory: directory.appendingPathComponent("control"))
        let target = try DataDirectoryMigration().migrate(store: store, parent: parent, location: location)
        let moved = try JotBloomStore(dataDirectoryURL: target, requireExisting: true)
        defer { moved.close() }
        XCTAssertEqual(try moved.promptSynchronously(id: saved.id)?.content, "搬迁原文")
        XCTAssertEqual(try moved.promptSynchronously(id: saved.id)?.sourceClipboardID, source)
        XCTAssertEqual(try moved.migrationRecordCounts(), try store.migrationRecordCounts())
    }

    func testInspirationExactDuplicateDoesNotConsumeDraftOrOverwrite() throws {
        let parsed = InspirationTextParser.parse("查重标题\n完整正文")!
        let first = try store.saveManualInspirationSynchronously(parsed, timestampUTCms: 1)
        try store.persistDraftSynchronously(kind: .inspiration, content: "查重标题\n完整正文", updatedAtUTCms: 2)
        XCTAssertThrowsError(try store.saveManualInspirationSynchronously(parsed, timestampUTCms: 3))
        XCTAssertEqual(try store.listRecentInspirationsSynchronously().count, 1)
        XCTAssertEqual(try store.inspirationSynchronously(id: first.id).updatedAtUTCms, 1)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "查重标题\n完整正文")
    }
    func testCrossEntryInspirationDuplicatesInBothDirections() async throws {
        let original = "同一标题\n同一段内容\n最后一行"
        let manual = try store.saveManualInspirationSynchronously(InspirationTextParser.parse(original)!, timestampUTCms: 1)
        let imported = try await store.saveClipboard(id: clipboard(original), to: .inspiration, timestamp: 2)
        XCTAssertFalse(imported.created); XCTAssertEqual(imported.id, manual.id)
        let another = "剪贴板先存\n完整正文"
        _ = try await store.saveClipboard(id: clipboard(another), to: .inspiration, timestamp: 3)
        XCTAssertThrowsError(try store.saveManualInspirationSynchronously(InspirationTextParser.parse(another)!, timestampUTCms: 4))
        XCTAssertEqual(try store.listRecentInspirationsSynchronously().count, 2)
    }
    func testInspirationDedupeBeyondFirstPageAndDistinctTextAllowed() throws {
        for index in 0..<65 {
            _ = try store.saveManualInspirationSynchronously(.init(title: "标题\(index)", body: "正文\(index)"), timestampUTCms: Int64(index))
        }
        XCTAssertThrowsError(try store.saveManualInspirationSynchronously(.init(title: "标题0", body: "正文0"), timestampUTCms: 100))
        _ = try store.saveManualInspirationSynchronously(.init(title: "标题0", body: "不同正文"), timestampUTCms: 101)
        _ = try store.saveManualInspirationSynchronously(.init(title: "不同标题", body: "正文0"), timestampUTCms: 102)
        _ = try store.saveManualInspirationSynchronously(.init(title: "标题0", body: "正文0 "), timestampUTCms: 103)
    }
    func testConcurrentInspirationDuplicatesAndEditGuard() async throws {
        let parsed = ParsedInspiration(title: "并发", body: "相同内容")
        async let a = store.saveManualInspiration(parsed, timestampUTCms: 1)
        async let b = store.saveManualInspiration(parsed, timestampUTCms: 2)
        _ = try? await a; _ = try? await b
        XCTAssertEqual(try store.listRecentInspirationsSynchronously().count, 1)
        let other = try store.saveManualInspirationSynchronously(.init(title: "其他", body: "原文"), timestampUTCms: 3)
        XCTAssertThrowsError(try store.updateInspirationTextSynchronously(id: other.id, title: parsed.title, body: parsed.completeText, updatedAtUTCms: 4))
        XCTAssertEqual(try store.inspirationSynchronously(id: other.id).body, "其他\n原文")
    }
    func testPromptOverwriteKeepsIdentityAndBlocksOldAI() async throws {
        let source = try clipboard("原始提示词")
        let id = try await store.saveClipboard(id: source, to: .prompt, timestamp: 1).id
        let old = try XCTUnwrap(store.promptSynchronously(id: id))
        let saved = try await store.savePromptEdits(id: id, title: "修改标题", content: "完整修改正文\n最后", asNew: false, token: "edit", timestamp: 20)
        XCTAssertEqual(saved, id)
        let result = try XCTUnwrap(store.promptSynchronously(id: id))
        XCTAssertEqual(result.content, "完整修改正文\n最后"); XCTAssertEqual(result.titleSource, .user)
        XCTAssertEqual(result.sourceClipboardID, source); XCTAssertEqual(result.createdAtUTCms, 1)
        XCTAssertFalse(try store.applyPromptTitleSynchronously("迟到标题", expected: old))
        XCTAssertEqual(try store.searchAllSynchronously(query: "完整修改").prompts.count, 1)
    }
    func testPromptSaveAsIndependentIdempotentAndDoesNotConsumeDraft() async throws {
        let id = try await store.saveClipboard(id: clipboard("原文"), to: .prompt, timestamp: 1).id
        try store.persistDraftSynchronously(kind: .inspiration, content: "不要清空的草稿", updatedAtUTCms: 2)
        let saved = try await store.savePromptEdits(id: id, title: "新标题", content: "新正文", asNew: true, token: "copy", timestamp: 3)
        let repeated = try await store.savePromptEdits(id: id, title: "新标题", content: "新正文", asNew: true, token: "copy", timestamp: 4)
        XCTAssertNotEqual(saved, id); XCTAssertEqual(saved, repeated)
        XCTAssertEqual(try store.promptSynchronously(id: id)?.content, "原文")
        XCTAssertNil(try store.promptSynchronously(id: saved)?.sourceClipboardID)
        XCTAssertEqual(try store.promptSynchronously(id: saved)?.titleSource, .user)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "不要清空的草稿")
    }
    func testPromptInvalidEditsDoNotOverwriteOrCreate() async throws {
        let id = try await input("保留原文")
        do { _ = try await store.savePromptEdits(id: id, title: " ", content: "正文", asNew: false, token: "bad", timestamp: 2); XCTFail() } catch {}
        do { _ = try await store.savePromptEdits(id: id, title: "标题", content: " ", asNew: true, token: "bad2", timestamp: 2); XCTFail() } catch {}
        XCTAssertEqual(try store.promptSynchronously(id: id)?.content, "保留原文")
        let rows = try await store.listPrompts(); XCTAssertEqual(rows.count, 1)
    }
}
