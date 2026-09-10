import Foundation
import XCTest
@testable import JotBloomCore

@MainActor
final class GlobalSearchViewModelTests: XCTestCase {
    func testAllShowsTwoPerSourceButCountsEveryMatchAndKeyboardSkipsHiddenRows() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["mix"] = snapshot(
            clipboard: (1...6).map { result(.clipboard, id: Int64($0)) },
            prompts: (1...3).map { result(.prompt, id: Int64($0)) },
            inspirations: [result(.inspiration, id: 1)])
        let model = makeContext(store: store, debounceNanoseconds: 0).viewModel
        model.query = "mix"
        try await waitUntil { model.phase == .results }
        XCTAssertEqual(model.count(for: .all), 10)
        XCTAssertEqual(model.count(for: .clipboard), 6)
        XCTAssertEqual(model.visibleResults.count, 5)
        model.moveSelection(by: 2)
        XCTAssertEqual(model.selectedID, resultID(.prompt, 1))
        model.select(resultID(.clipboard, 6))
        XCTAssertEqual(model.selectedID, resultID(.prompt, 1))
        model.selectScope(.clipboard)
        XCTAssertEqual(model.visibleResults.count, 6)
        model.moveSelection(by: 5)
        XCTAssertEqual(model.selectedID, resultID(.clipboard, 6))
        model.selectScope(.all)
        XCTAssertEqual(model.selectedID, resultID(.clipboard, 1))
        XCTAssertEqual(store.searchRequests, ["mix"])
    }

    func testScopeAndSelectedRecordSurviveEditorRefreshAndDeletedRecordFallsBack() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["mix"] = snapshot(prompts: (1...4).map { result(.prompt, id: Int64($0)) })
        let model = makeContext(store: store, debounceNanoseconds: 0).viewModel
        model.query = "mix"
        try await waitUntil { model.phase == .results }
        model.selectScope(.prompt)
        model.select(resultID(.prompt, 4))
        model.refresh(preferredID: resultID(.prompt, 4))
        try await waitUntil { model.phase == .results }
        XCTAssertEqual(model.scope, .prompt)
        XCTAssertEqual(model.query, "mix")
        XCTAssertEqual(model.selectedID, resultID(.prompt, 4))
        store.snapshots["mix"] = snapshot(prompts: [result(.prompt, id: 1)])
        model.refresh()
        try await waitUntil { model.phase == .results }
        XCTAssertEqual(model.selectedID, resultID(.prompt, 1))
        XCTAssertEqual(model.count(for: .prompt), 1)
    }

    func testEmptyCategoryKeepsQueryAndCannotActivateHiddenResult() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["mix"] = snapshot(clipboard: [result(.clipboard, id: 1)])
        let model = makeContext(store: store, debounceNanoseconds: 0).viewModel
        model.query = "mix"
        try await waitUntil { model.phase == .results }
        model.selectScope(.prompt)
        XCTAssertEqual(model.count(for: .prompt), 0)
        XCTAssertTrue(model.visibleResults.isEmpty)
        XCTAssertNil(model.selectedID)
        model.activate(resultID(.clipboard, 1))
        XCTAssertFalse(model.copySelectedWithoutCollapsing())
        XCTAssertTrue(store.clipboardReadRequests.isEmpty)
        model.selectScope(.all)
        XCTAssertEqual(model.query, "mix")
        XCTAssertEqual(model.selectedID, resultID(.clipboard, 1))
        model.selectScope(.inspiration)
        model.resetForPanelDismissal()
        XCTAssertEqual(model.scope, .all)
    }

    func testScopeSwitchDuringSearchAppliesLatestScopeAndRetainsItWhileTyping() async throws {
        let store = FakeGlobalSearchStore()
        store.delays["mix"] = 20_000_000
        store.snapshots["mix"] = snapshot(clipboard: [result(.clipboard, id: 1)], prompts: [result(.prompt, id: 2)])
        let model = makeContext(store: store, debounceNanoseconds: 0).viewModel
        model.query = "mix"
        model.selectScope(.prompt)
        try await waitUntil { model.phase == .results }
        XCTAssertEqual(model.selectedID, resultID(.prompt, 2))
        model.query = "none"
        try await waitUntil { model.phase == .empty }
        XCTAssertEqual(model.scope, .prompt)
        XCTAssertEqual(model.count(for: .all), 0)
        XCTAssertNil(model.selectedID)
    }

    func testScopeSwitchCancelsPendingClipboardCopy() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["mix"] = snapshot(clipboard: [result(.clipboard, id: 1)])
        store.clipboardTexts[1] = "private copy"
        store.clipboardReadDelays[1] = 80_000_000
        let context = makeContext(store: store, debounceNanoseconds: 0)
        context.viewModel.query = "mix"
        try await waitUntil { context.viewModel.phase == .results }
        var collapsed = false
        context.viewModel.onRequestCollapse = { collapsed = true }
        context.viewModel.activateSelected()
        try await waitUntil { !store.clipboardReadRequests.isEmpty }
        context.viewModel.selectScope(.prompt)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(collapsed)
        XCTAssertNil(context.writer.text)
    }

    func testDebounceCancelsEarlierIntentAndSubmitsLatestQueryOnly() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["latest"] = snapshot(clipboard: [result(.clipboard, id: 2)])
        let context = makeContext(store: store, debounceNanoseconds: 40_000_000)

        context.viewModel.query = "first"
        XCTAssertEqual(context.viewModel.phase, .debouncing)
        try await Task.sleep(nanoseconds: 10_000_000)
        context.viewModel.query = "latest"
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(store.searchRequests, [])

        try await waitUntil { context.viewModel.phase == .results }
        XCTAssertEqual(store.searchRequests, ["latest"])
        XCTAssertEqual(context.viewModel.selectedID, resultID(.clipboard, 2))
    }

    func testCancelledSlowResultCannotReplaceNewerSnapshot() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["old"] = snapshot(clipboard: [result(.clipboard, id: 1)])
        store.snapshots["new"] = snapshot(inspirations: [result(.inspiration, id: 9)])
        store.delays["old"] = 80_000_000
        store.delays["new"] = 2_000_000
        store.ignoreCancellationForDelayedSearch = true
        let context = makeContext(store: store, debounceNanoseconds: 0)

        context.viewModel.query = "old"
        try await waitUntil { store.searchRequests == ["old"] }
        context.viewModel.query = "new"
        try await waitUntil {
            context.viewModel.snapshot.inspirations.first?.id.recordID == 9
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(context.viewModel.phase, .results)
        XCTAssertEqual(context.viewModel.snapshot.inspirations.map(\.id.recordID), [9])
        XCTAssertTrue(context.viewModel.snapshot.clipboard.isEmpty)
    }

    func testIdleEmptyFailureAndRetryRemainDistinct() async throws {
        let store = FakeGlobalSearchStore()
        let context = makeContext(store: store, debounceNanoseconds: 0)

        context.viewModel.query = "   \n"
        XCTAssertEqual(context.viewModel.phase, .idle)
        XCTAssertTrue(store.searchRequests.isEmpty)

        store.snapshots["result"] = snapshot(
            clipboard: [result(.clipboard, id: 1)]
        )
        context.viewModel.query = "result"
        try await waitUntil { context.viewModel.phase == .results }

        store.failuresRemaining = 1
        context.viewModel.query = "broken"
        try await waitUntil { context.viewModel.phase == .failure }
        XCTAssertEqual(context.viewModel.snapshot, .empty)
        XCTAssertNil(context.viewModel.selectedID)
        context.viewModel.retry()
        try await waitUntil { context.viewModel.phase == .empty }

        context.viewModel.query = "none"
        try await waitUntil { context.viewModel.phase == .empty }

        XCTAssertEqual(
            store.searchRequests,
            ["result", "broken", "broken", "none"]
        )
    }

    func testSelectionCrossesGroupsStopsAtBoundsAndFallsBackByIndex() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["one"] = snapshot(
            clipboard: [result(.clipboard, id: 3), result(.clipboard, id: 2)],
            inspirations: [result(.inspiration, id: 1)]
        )
        store.snapshots["two"] = snapshot(
            clipboard: [result(.clipboard, id: 4)],
            inspirations: [result(.inspiration, id: 1)]
        )
        let context = makeContext(store: store, debounceNanoseconds: 0)
        context.viewModel.query = "one"
        try await waitUntil { context.viewModel.phase == .results }

        context.viewModel.moveSelection(by: 1)
        context.viewModel.moveSelection(by: 1)
        context.viewModel.moveSelection(by: 1)
        XCTAssertEqual(context.viewModel.selectedID, resultID(.inspiration, 1))
        context.viewModel.moveSelection(by: -1)
        XCTAssertEqual(context.viewModel.selectedID, resultID(.clipboard, 2))

        context.viewModel.query = "two"
        try await waitUntil {
            context.viewModel.phase == .results
                && context.viewModel.snapshot.clipboard.first?.id.recordID == 4
        }
        XCTAssertEqual(context.viewModel.selectedID, resultID(.inspiration, 1))
    }

    func testActivateRefreshesCurrentQueryAndDismissalClearsSession() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["keep"] = snapshot(clipboard: [result(.clipboard, id: 1)])
        let context = makeContext(store: store, debounceNanoseconds: 0)
        context.viewModel.query = "keep"
        try await waitUntil { context.viewModel.phase == .results }
        let focusBefore = context.viewModel.focusRequest

        context.viewModel.activate()
        try await waitUntil { store.searchRequests.count == 2 }
        XCTAssertEqual(context.viewModel.focusRequest, focusBefore + 1)
        XCTAssertEqual(context.viewModel.query, "keep")

        context.viewModel.resetForPanelDismissal()
        XCTAssertEqual(context.viewModel.query, "")
        XCTAssertEqual(context.viewModel.phase, .idle)
        XCTAssertEqual(context.viewModel.snapshot, .empty)
        XCTAssertNil(context.viewModel.selectedID)
        XCTAssertNil(context.viewModel.feedback)
    }

    func testPrimaryClipboardActionReadsExactTextAdvancesBaselineAndCollapses() async throws {
        let store = FakeGlobalSearchStore()
        let item = result(.clipboard, id: 7)
        store.snapshots["copy"] = snapshot(clipboard: [item])
        store.clipboardTexts[7] = " exact\n原文 "
        let context = makeContext(store: store, debounceNanoseconds: 0)
        var baseline: Int?
        var collapseCount = 0
        context.viewModel.onPasteboardWritten = { baseline = $0 }
        context.viewModel.onRequestCollapse = { collapseCount += 1 }
        context.viewModel.query = "copy"
        try await waitUntil { context.viewModel.phase == .results }

        context.viewModel.activateSelected()
        try await waitUntil { context.writer.text == " exact\n原文 " }

        XCTAssertEqual(baseline, context.writer.changeCount)
        XCTAssertEqual(collapseCount, 1)
        XCTAssertNil(context.viewModel.feedback)
    }

    func testCommandCopyKeepsPanelOpenAndExpiresFeedback() async throws {
        let store = FakeGlobalSearchStore()
        let item = result(.clipboard, id: 8)
        store.snapshots["copy"] = snapshot(clipboard: [item])
        store.clipboardTexts[8] = "copy"
        let context = makeContext(
            store: store,
            debounceNanoseconds: 0,
            copiedFeedbackNanoseconds: 25_000_000
        )
        var collapseCount = 0
        context.viewModel.onRequestCollapse = { collapseCount += 1 }
        context.viewModel.query = "copy"
        try await waitUntil { context.viewModel.phase == .results }

        XCTAssertTrue(context.viewModel.copySelectedWithoutCollapsing())
        try await waitUntil { context.viewModel.feedback?.kind == .copied }
        XCTAssertEqual(context.viewModel.copiedResultID, item.id)
        XCTAssertEqual(collapseCount, 0)
        try await waitUntil { context.viewModel.feedback == nil }
        XCTAssertNil(context.viewModel.copiedResultID)
    }

    func testNewClipboardActionSupersedesAnInFlightCopy() async throws {
        let store = FakeGlobalSearchStore()
        let first = result(.clipboard, id: 1)
        let second = result(.clipboard, id: 2)
        store.snapshots["copy"] = snapshot(clipboard: [first, second])
        store.clipboardTexts[1] = "first"
        store.clipboardTexts[2] = "second"
        store.clipboardReadDelays[1] = 80_000_000
        let context = makeContext(store: store, debounceNanoseconds: 0)
        var collapseCount = 0
        context.viewModel.onRequestCollapse = { collapseCount += 1 }
        context.viewModel.query = "copy"
        try await waitUntil { context.viewModel.phase == .results }

        XCTAssertTrue(context.viewModel.copySelectedWithoutCollapsing())
        context.viewModel.select(second.id)
        context.viewModel.activateSelected()
        try await waitUntil {
            context.writer.text == "second" && collapseCount == 1
        }

        XCTAssertEqual(context.writer.changeCount, 1)
        XCTAssertEqual(store.clipboardReadRequests.last, 2)
        XCTAssertNil(context.viewModel.feedback)
    }

    func testMissingClipboardResultKeepsPageShowsErrorAndRefreshes() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["gone"] = snapshot(clipboard: [result(.clipboard, id: 4)])
        let context = makeContext(store: store, debounceNanoseconds: 0)
        var collapseCount = 0
        context.viewModel.onRequestCollapse = { collapseCount += 1 }
        context.viewModel.query = "gone"
        try await waitUntil { context.viewModel.phase == .results }

        context.viewModel.activateSelected()
        try await waitUntil {
            context.viewModel.feedback?.message == "这条内容已不存在，请重新搜索。"
                && store.searchRequests.count == 2
        }

        XCTAssertEqual(collapseCount, 0)
        XCTAssertNil(context.writer.text)
    }

    func testPasteboardFailureDoesNotCollapseOrLoseResults() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["copy"] = snapshot(clipboard: [result(.clipboard, id: 5)])
        store.clipboardTexts[5] = "copy"
        let context = makeContext(store: store, debounceNanoseconds: 0)
        context.writer.shouldFail = true
        var collapseCount = 0
        context.viewModel.onRequestCollapse = { collapseCount += 1 }
        context.viewModel.query = "copy"
        try await waitUntil { context.viewModel.phase == .results }

        context.viewModel.activateSelected()
        try await waitUntil { context.viewModel.feedback?.kind == .error }

        XCTAssertEqual(context.viewModel.feedback?.message, "无法复制这条内容。")
        XCTAssertEqual(context.viewModel.snapshot.clipboard.count, 1)
        XCTAssertEqual(collapseCount, 0)
    }

    func testInspirationAndPromptEmitSeparateEditorIDs() async throws {
        let store = FakeGlobalSearchStore()
        store.snapshots["mixed"] = snapshot(
            prompts: [result(.prompt, id: 6)],
            inspirations: [result(.inspiration, id: 42)]
        )
        let context = makeContext(store: store, debounceNanoseconds: 0)
        var openedIDs: [Int64] = []
        var openedPromptIDs: [Int64] = []
        context.viewModel.onOpenInspiration = { openedIDs.append($0) }
        context.viewModel.onOpenPrompt = { openedPromptIDs.append($0) }
        context.viewModel.query = "mixed"
        try await waitUntil { context.viewModel.phase == .results }

        context.viewModel.activate(resultID(.prompt, 6))
        XCTAssertTrue(openedIDs.isEmpty)
        XCTAssertEqual(openedPromptIDs, [6])
        XCTAssertTrue(context.viewModel.copySelectedWithoutCollapsing())
        context.viewModel.activate(resultID(.inspiration, 42))

        XCTAssertEqual(openedIDs, [42])
        XCTAssertFalse(context.viewModel.copySelectedWithoutCollapsing())
    }

    private func makeContext(
        store: FakeGlobalSearchStore,
        debounceNanoseconds: UInt64,
        copiedFeedbackNanoseconds: UInt64 = 800_000_000
    ) -> GlobalSearchViewModelTestContext {
        let writer = FakeGlobalSearchWriter()
        let viewModel = GlobalSearchViewModel(
            store: store,
            pasteboardWriter: writer,
            debounceNanoseconds: debounceNanoseconds,
            copiedFeedbackNanoseconds: copiedFeedbackNanoseconds
        )
        return GlobalSearchViewModelTestContext(
            viewModel: viewModel,
            writer: writer
        )
    }

    private func result(
        _ source: SearchResultSource,
        id: Int64
    ) -> GlobalSearchResult {
        GlobalSearchResult(
            id: resultID(source, id),
            source: source,
            leadingKind: source == .inspiration ? .inspiration : .text,
            segments: [SearchTextSegment(text: "result-\(id)", isHighlighted: true)],
            timestampUTCms: id,
            accessibilityContext: "result \(id)"
        )
    }

    private func resultID(
        _ source: SearchResultSource,
        _ id: Int64
    ) -> SearchResultID {
        SearchResultID(source: source, recordID: id)
    }

    private func snapshot(
        clipboard: [GlobalSearchResult] = [],
        prompts: [GlobalSearchResult] = [],
        inspirations: [GlobalSearchResult] = []
    ) -> GlobalSearchSnapshot {
        GlobalSearchSnapshot(
            clipboard: clipboard,
            prompts: prompts,
            inspirations: inspirations
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - started > timeoutNanoseconds {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
private struct GlobalSearchViewModelTestContext {
    let viewModel: GlobalSearchViewModel
    let writer: FakeGlobalSearchWriter
}

@MainActor
private final class FakeGlobalSearchStore: GlobalSearchStoring {
    var snapshots: [String: GlobalSearchSnapshot] = [:]
    var clipboardTexts: [Int64: String] = [:]
    var clipboardReadDelays: [Int64: UInt64] = [:]
    var delays: [String: UInt64] = [:]
    var failuresRemaining = 0
    var ignoreCancellationForDelayedSearch = false
    private(set) var searchRequests: [String] = []
    private(set) var clipboardReadRequests: [Int64] = []

    func searchAll(query: String) async throws -> GlobalSearchSnapshot {
        searchRequests.append(query)
        if let delay = delays[query] {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch where ignoreCancellationForDelayedSearch {
                // Simulates a synchronous SQLite scan that cannot stop mid-query.
            }
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw FakeGlobalSearchError.failed
        }
        return snapshots[query] ?? .empty
    }

    func searchableClipboardText(id: Int64) async throws -> String? {
        clipboardReadRequests.append(id)
        if let delay = clipboardReadDelays[id] {
            try await Task.sleep(nanoseconds: delay)
        }
        return clipboardTexts[id]
    }
}

@MainActor
private final class FakeGlobalSearchWriter: ClipboardWriting {
    var shouldFail = false
    private(set) var text: String?
    private(set) var changeCount = 0

    func writeText(_ text: String) throws -> Int {
        if shouldFail { throw FakeGlobalSearchError.failed }
        self.text = text
        changeCount += 1
        return changeCount
    }

    func writePNGData(_ data: Data) throws -> Int {
        throw FakeGlobalSearchError.failed
    }
}

private enum FakeGlobalSearchError: Error {
    case failed
}
