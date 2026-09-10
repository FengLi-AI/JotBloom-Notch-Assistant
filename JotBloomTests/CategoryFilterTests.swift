import XCTest
@testable import JotBloomCore

@MainActor
final class CategoryFilterTests: XCTestCase {
    func testFilterBeforePaginationIncludesRecordsBeyondAllFirstPage() async throws {
        let directory = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory); defer { store.close() }
        let db = try SQLiteConnection(databaseURL: directory.appendingPathComponent(DataDirectoryResolver.databaseFileName)); defer { db.close() }
        try db.transaction {
            for index in 1...180 {
                try db.execute("INSERT INTO inspirations(title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source,sort_order) VALUES('标题\(index)','正文\(index)','\(index <= 101 ? InspirationCategory.article.rawValue : InspirationCategory.idea.rawValue)','user',1,1,'manual',\(index))", operation: "fixture")
            }
        }
        let all = try await store.listInspirationsPage(after: nil, limit: 50)
        XCTAssertTrue(all.items.allSatisfy { $0.category == .idea })
        let first = try await store.listInspirationsPage(after: nil, limit: 50, category: .article)
        let second = try await store.listInspirationsPage(after: first.nextCursor, limit: 50, category: .article)
        let third = try await store.listInspirationsPage(after: second.nextCursor, limit: 50, category: .article)
        XCTAssertEqual(first.items.count, 50); XCTAssertEqual(second.items.count, 50); XCTAssertEqual(third.items.count, 1)
        XCTAssertEqual(Set((first.items + second.items + third.items).map(\.id)).count, 101)
        XCTAssertEqual(first.items.first?.id, 101)
        let work = try await store.listInspirationsPage(after: nil, limit: 50, category: .work); XCTAssertTrue(work.items.isEmpty)
        let model = InspirationLibraryViewModel(store: store)
        model.filter(.article); model.filter(.idea); model.filter(.work)
        for _ in 0..<200 { if model.isReady { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.isReady); XCTAssertEqual(model.filterCategory, .work); XCTAssertTrue(model.items.isEmpty)
        let othersBefore = all.items.map(\.id)
        try await store.reorderLibrary(.inspirations, id: 1, relativeTo: 101, category: .article)
        let sorted = try await store.listInspirationsPage(after: nil, limit: 50, category: .article)
        let allAfter = try await store.listInspirationsPage(after: nil, limit: 50)
        XCTAssertEqual(sorted.items.first?.id, 1); XCTAssertEqual(allAfter.items.map(\.id), othersBefore)
        do { try await store.reorderLibrary(.inspirations, id: 180, relativeTo: 101, category: .article); XCTFail() } catch { XCTAssertEqual(error as? PromptError, .missing) }
        _ = try store.updateInspirationCategorySynchronously(id: 1, category: .work, updatedAtUTCms: 2)
        let changed = try await store.listInspirationsPage(after: nil, limit: 50, category: .article)
        XCTAssertFalse(changed.items.contains { $0.id == 1 })
        let deleted = try await store.deleteInspiration(id: 1); _ = try await store.restoreInspiration(deleted)
        let restored = try await store.listInspirationsPage(after: nil, limit: 50, category: .work)
        XCTAssertEqual(restored.items.map(\.id), [1])
    }
}
