import XCTest
@testable import JotBloomCore

@MainActor
final class InspirationInputViewModelTests: XCTestCase {
    func testStartLoadsDraftAndRecentInspirationsOnlyOnce() async {
        let inspiration = makeInspiration(id: 7, title: "已有灵感")
        let store = InspirationStoreSpy(
            draftToLoad: Draft(
                id: 1,
                kind: .inspiration,
                content: "未完成草稿",
                updatedAtUTCms: 1
            ),
            recentToLoad: [inspiration]
        )
        let subject = InspirationInputViewModel(store: store)

        subject.start()
        subject.start()
        let becameReady = await waitUntil { subject.isReady }

        XCTAssertTrue(becameReady)
        XCTAssertEqual(subject.text, "未完成草稿")
        XCTAssertEqual(subject.recentInspirations, [inspiration])
        XCTAssertEqual(store.loadDraftCallCount, 1)
        XCTAssertEqual(store.listRecentCallCount, 1)
        XCTAssertEqual(store.persistedDrafts.count, 0)
    }

    func testDebouncePersistsOnlyLatestText() async {
        let store = InspirationStoreSpy()
        let subject = InspirationInputViewModel(
            store: store,
            debounceNanoseconds: 20_000_000,
            nowUTCms: { 42 }
        )
        subject.start()
        _ = await waitUntil { subject.isReady }

        subject.text = "第一个版本"
        subject.text = "最终版本"
        let persisted = await waitUntil { store.persistedDrafts.count == 1 }

        XCTAssertTrue(persisted)
        XCTAssertEqual(store.persistedDrafts.first?.kind, .inspiration)
        XCTAssertEqual(store.persistedDrafts.first?.content, "最终版本")
        XCTAssertEqual(store.persistedDrafts.first?.timestampUTCms, 42)
    }

    func testTabActivationRefreshesRecentInspirationsFromStore() async {
        let oldValue = makeInspiration(id: 1, title: "旧标题")
        let newValue = makeInspiration(id: 1, title: "编辑后的标题")
        let store = InspirationStoreSpy(recentToLoad: [oldValue])
        let subject = InspirationInputViewModel(store: store)
        subject.start()
        _ = await waitUntil { subject.isReady }
        store.recentToLoad = [newValue]

        subject.refreshRecentInspirations()
        let refreshed = await waitUntil {
            subject.recentInspirations == [newValue]
        }

        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.listRecentCallCount, 2)
    }

    func testSuccessfulSaveClearsMatchingInputAndAddsRecentItem() async {
        let store = InspirationStoreSpy()
        let subject = InspirationInputViewModel(
            store: store,
            debounceNanoseconds: 1_000_000_000,
            nowUTCms: { 101 }
        )
        subject.start()
        _ = await waitUntil { subject.isReady }
        subject.text = "标题\n正文"

        subject.save()
        let completed = await waitUntil { store.savedValues.count == 1 && !subject.isSaving }

        XCTAssertTrue(completed)
        XCTAssertEqual(store.savedValues.first?.parsed.title, "标题")
        XCTAssertEqual(store.savedValues.first?.parsed.body, "正文")
        XCTAssertEqual(store.savedValues.first?.timestampUTCms, 101)
        XCTAssertEqual(subject.text, "")
        XCTAssertEqual(subject.recentInspirations.first?.title, "标题")
        XCTAssertEqual(subject.feedback, .init(kind: .success, message: "已保存"))
        XCTAssertFalse(subject.canSave)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.persistedDrafts.count, 0)
    }

    func testSecondSaveRequestIsIgnoredWhileFirstIsInFlight() async {
        let store = InspirationStoreSpy()
        store.saveDelayNanoseconds = 80_000_000
        let subject = InspirationInputViewModel(store: store)
        subject.start()
        _ = await waitUntil { subject.isReady }
        subject.text = "只保存一次"

        subject.save()
        subject.save()
        let completed = await waitUntil { !subject.isSaving && store.saveCallCount == 1 }

        XCTAssertTrue(completed)
        XCTAssertEqual(store.saveCallCount, 1)
    }

    func testTextChangedDuringSaveIsKeptAndPersistedAsNewDraft() async {
        let store = InspirationStoreSpy()
        store.saveDelayNanoseconds = 60_000_000
        let subject = InspirationInputViewModel(
            store: store,
            debounceNanoseconds: 20_000_000,
            nowUTCms: { 202 }
        )
        subject.start()
        _ = await waitUntil { subject.isReady }
        subject.text = "准备保存的内容"

        subject.save()
        subject.text = "保存期间新写的内容"
        let persisted = await waitUntil {
            !subject.isSaving
                && store.persistedDrafts.contains { $0.content == "保存期间新写的内容" }
        }

        XCTAssertTrue(persisted)
        XCTAssertEqual(subject.text, "保存期间新写的内容")
        XCTAssertEqual(subject.recentInspirations.first?.title, "准备保存的内容")
    }

    func testSaveFailureKeepsInputAndFallsBackToDraftPersistence() async {
        let store = InspirationStoreSpy()
        store.saveError = InspirationStoreSpy.TestError.forcedFailure
        let subject = InspirationInputViewModel(
            store: store,
            debounceNanoseconds: 20_000_000
        )
        subject.start()
        _ = await waitUntil { subject.isReady }
        subject.text = "不能丢失"

        subject.save()
        let persisted = await waitUntil {
            !subject.isSaving && store.persistedDrafts.contains { $0.content == "不能丢失" }
        }

        XCTAssertTrue(persisted)
        XCTAssertEqual(subject.text, "不能丢失")
        XCTAssertEqual(subject.feedback?.kind, .error)
    }

    func testTerminationFlushesTextBeforeLongDebounceExpires() async throws {
        let store = InspirationStoreSpy()
        let subject = InspirationInputViewModel(
            store: store,
            debounceNanoseconds: 5_000_000_000,
            nowUTCms: { 303 }
        )
        subject.start()
        _ = await waitUntil { subject.isReady }
        subject.text = "退出前草稿"

        try await subject.prepareForTermination()

        XCTAssertEqual(store.persistedDrafts.count, 1)
        XCTAssertEqual(store.persistedDrafts.first?.content, "退出前草稿")
        XCTAssertEqual(store.persistedDrafts.first?.timestampUTCms, 303)
    }

    func testTerminationWaitsForSaveThenFlushesClearedState() async throws {
        let store = InspirationStoreSpy()
        store.saveDelayNanoseconds = 60_000_000
        let subject = InspirationInputViewModel(
            store: store,
            debounceNanoseconds: 5_000_000_000,
            nowUTCms: { 404 }
        )
        subject.start()
        _ = await waitUntil { subject.isReady }
        subject.text = "正在保存"
        subject.save()

        XCTAssertTrue(subject.hasPendingSave)
        await subject.waitForPendingSave()
        try subject.flushDraftSynchronously()

        XCTAssertFalse(subject.hasPendingSave)
        XCTAssertEqual(subject.text, "")
        XCTAssertEqual(store.persistedDrafts.count, 1)
        XCTAssertEqual(store.persistedDrafts.first?.content, "")
    }

    func testLoadFailureKeepsInputUnavailableAndShowsError() async {
        let store = InspirationStoreSpy()
        store.loadError = InspirationStoreSpy.TestError.forcedFailure
        let subject = InspirationInputViewModel(store: store)

        subject.start()
        let failed = await waitUntil { subject.feedback?.kind == .error }

        XCTAssertTrue(failed)
        XCTAssertFalse(subject.isReady)
        XCTAssertFalse(subject.canSave)
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func makeInspiration(id: Int64, title: String) -> Inspiration {
        Inspiration(
            id: id,
            title: title,
            body: title,
            category: .idea,
            categorySource: .fallback,
            createdAtUTCms: id,
            updatedAtUTCms: id,
            source: .manual
        )
    }
}

@MainActor
private final class InspirationStoreSpy: InspirationStoring {
    enum TestError: Error {
        case forcedFailure
    }

    struct PersistedDraft {
        let kind: DraftKind
        let content: String
        let timestampUTCms: Int64
    }

    struct SavedValue {
        let parsed: ParsedInspiration
        let timestampUTCms: Int64
    }

    var draftToLoad: Draft?
    var recentToLoad: [Inspiration]
    var loadError: Error?
    var persistError: Error?
    var saveError: Error?
    var saveDelayNanoseconds: UInt64 = 0

    private(set) var loadDraftCallCount = 0
    private(set) var listRecentCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var persistedDrafts: [PersistedDraft] = []
    private(set) var savedValues: [SavedValue] = []

    init(draftToLoad: Draft? = nil, recentToLoad: [Inspiration] = []) {
        self.draftToLoad = draftToLoad
        self.recentToLoad = recentToLoad
    }

    func loadDraft(kind: DraftKind) async throws -> Draft? {
        loadDraftCallCount += 1
        if let loadError { throw loadError }
        return draftToLoad
    }

    func persistDraft(
        kind: DraftKind,
        content: String,
        updatedAtUTCms: Int64
    ) async throws {
        if let persistError { throw persistError }
        persistedDrafts.append(
            PersistedDraft(
                kind: kind,
                content: content,
                timestampUTCms: updatedAtUTCms
            )
        )
    }

    func persistDraftSynchronously(
        kind: DraftKind,
        content: String,
        updatedAtUTCms: Int64
    ) throws {
        if let persistError { throw persistError }
        persistedDrafts.append(
            PersistedDraft(
                kind: kind,
                content: content,
                timestampUTCms: updatedAtUTCms
            )
        )
    }

    func saveManualInspiration(
        _ parsed: ParsedInspiration,
        timestampUTCms: Int64
    ) async throws -> Inspiration {
        saveCallCount += 1
        if saveDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: saveDelayNanoseconds)
        }
        if let saveError { throw saveError }
        savedValues.append(
            SavedValue(parsed: parsed, timestampUTCms: timestampUTCms)
        )
        return Inspiration(
            id: Int64(saveCallCount),
            title: parsed.title,
            body: parsed.body,
            category: .idea,
            categorySource: .fallback,
            createdAtUTCms: timestampUTCms,
            updatedAtUTCms: timestampUTCms,
            source: .manual
        )
    }

    func listRecentInspirations(limit: Int) async throws -> [Inspiration] {
        listRecentCallCount += 1
        if let loadError { throw loadError }
        return Array(recentToLoad.prefix(limit))
    }
}
