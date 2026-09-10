import Foundation
import XCTest
@testable import JotBloomCore

@MainActor
final class InspirationLibraryViewModelTests: XCTestCase {
    func testAutoSaveStatusPersistsAndAIErrorDoesNotMeanLocalFailure() async throws {
        let context = makeContext(items: [inspiration(id: 1)], debounceNanoseconds: 20_000_000)
        context.viewModel.start(); try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected(); try await waitUntil { !context.viewModel.isDetailLoading }
        XCTAssertEqual(context.viewModel.saveStatusMessage, "已保存")
        context.viewModel.detailBody = "修改后的正文"
        XCTAssertEqual(context.viewModel.saveStatusMessage, "自动保存中…")
        try await waitUntil { !context.viewModel.hasPendingSave }
        XCTAssertEqual(context.viewModel.saveStatusMessage, "已保存")
        context.viewModel.showAIStatus("原文已保存，AI 整理暂不可用")
        XCTAssertEqual(context.viewModel.saveStatusMessage, "已保存")
        XCTAssertFalse(context.viewModel.textSaveFailed)
    }
    func testSaveFailureHasRetryAndPreservesEditedText() async throws {
        let context = makeContext(items: [inspiration(id: 1)], debounceNanoseconds: 20_000_000)
        context.viewModel.start(); try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected(); try await waitUntil { !context.viewModel.isDetailLoading }
        context.store.failTextUpdates = true
        context.viewModel.detailBody = "不能丢失的正文"
        try await waitUntil { context.viewModel.textSaveFailed && !context.viewModel.isSavingText }
        XCTAssertEqual(context.viewModel.saveStatusMessage, "保存失败，修改仍保留")
        XCTAssertEqual(context.viewModel.detailBody, "不能丢失的正文")
        context.store.failTextUpdates = false
        context.viewModel.commandSave()
        try await waitUntil { !context.viewModel.hasPendingSave }
        XCTAssertEqual(context.viewModel.saveStatusMessage, "已保存")
        XCTAssertFalse(context.viewModel.textSaveFailed)
        XCTAssertEqual(context.store.item(id: 1)?.body, "不能丢失的正文")
    }
    func testAIRefreshUpdatesOpenDetailWithoutRefocusing() async throws {
        let context = makeContext(items: [inspiration(id: 1, title: "旧标题")])
        context.viewModel.start(); try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected(); try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.store.replace(inspiration(id: 1, title: "AI 短标题", category: .article))
        await context.viewModel.refreshAfterAI(id: 1)
        XCTAssertEqual(context.viewModel.detailTitle, "AI 短标题")
        XCTAssertEqual(context.viewModel.detailCategory, .article)
        XCTAssertEqual(context.viewModel.detailFocusRequest, 1)
        XCTAssertTrue(context.store.textUpdates.isEmpty)
    }

    func testAIRefreshDoesNotReplaceUnsavedOrNewerEdits() async throws {
        let context = makeContext(items: [inspiration(id: 1)], debounceNanoseconds: 10_000_000_000)
        context.viewModel.start(); try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected(); try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.store.detailDelayNanoseconds = 80_000_000
        let refresh = Task { await context.viewModel.refreshAfterAI(id: 1) }
        try await Task.sleep(nanoseconds: 10_000_000)
        context.viewModel.detailTitle = "还没保存的人工标题"
        await refresh.value
        XCTAssertEqual(context.viewModel.detailTitle, "还没保存的人工标题")
        await context.viewModel.refreshAfterAI(id: 1)
        XCTAssertEqual(context.viewModel.detailTitle, "还没保存的人工标题")
        _ = await context.viewModel.prepareForTermination()
    }

    func testAIRefreshCannotReplaceAnotherDetailAfterNavigation() async throws {
        let context = makeContext(items: [inspiration(id: 1), inspiration(id: 2, title: "第二条")])
        context.viewModel.start(); try await waitUntil { context.viewModel.isReady }
        _ = context.viewModel.open(identifier: 1)
        try await waitUntil { context.viewModel.detailInspiration?.id == 1 && !context.viewModel.isDetailLoading }
        context.store.detailDelayNanoseconds = 80_000_000
        let refresh = Task { await context.viewModel.refreshAfterAI(id: 1) }
        try await Task.sleep(nanoseconds: 10_000_000)
        context.viewModel.returnToList()
        try await waitUntil { context.viewModel.screen == .list && !context.viewModel.isInitialLoading }
        _ = context.viewModel.open(identifier: 2)
        await refresh.value
        try await waitUntil { context.viewModel.detailInspiration?.id == 2 && !context.viewModel.isDetailLoading }
        XCTAssertEqual(context.viewModel.detailTitle, "第二条")
    }

    func testStartSelectsFirstItemAndLoadsAdditionalPageOnce() async throws {
        let values = (1...65).map { inspiration(id: Int64($0), updatedAt: Int64($0)) }
        let context = makeContext(items: values)

        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        XCTAssertEqual(context.viewModel.items.count, 50)
        XCTAssertEqual(context.viewModel.selectedID, 65)
        XCTAssertTrue(context.viewModel.canLoadMore)
        context.viewModel.loadNextPage()
        context.viewModel.loadNextPage()
        try await waitUntil { context.viewModel.items.count == 65 }
        XCTAssertFalse(context.viewModel.canLoadMore)
        XCTAssertEqual(Set(context.viewModel.items.map(\.id)).count, 65)
        XCTAssertEqual(context.store.pageRequests.count, 2)
    }

    func testFirstPageRefreshBlocksConcurrentNextPageLoad() async throws {
        let values = (1...65).map {
            inspiration(id: Int64($0), updatedAt: Int64($0))
        }
        let context = makeContext(items: values)
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.store.pageDelayNanoseconds = 40_000_000

        context.viewModel.activate()
        context.viewModel.loadNextPage()
        try await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertTrue(context.viewModel.isInitialLoading)
        XCTAssertEqual(context.store.pageRequests.count, 2)
        try await waitUntil { !context.viewModel.isInitialLoading }

        context.viewModel.loadNextPage()
        try await waitUntil { context.viewModel.items.count == 65 }
        XCTAssertEqual(context.store.pageRequests.count, 3)
        XCTAssertEqual(Set(context.viewModel.items.map(\.id)).count, 65)
    }

    func testArrowSelectionStopsAtBoundsAndRequestsNextPageNearEnd() async throws {
        let values = (1...7).map { inspiration(id: Int64($0), updatedAt: Int64($0)) }
        let context = makeContext(items: values, pageLimit: 5)
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.moveSelection(by: -1)
        XCTAssertEqual(context.viewModel.selectedID, 7)
        for _ in 0..<4 {
            context.viewModel.moveSelection(by: 1)
        }
        try await waitUntil { context.viewModel.items.count == 7 }
        context.viewModel.moveSelection(by: 1)
        context.viewModel.moveSelection(by: 1)
        context.viewModel.moveSelection(by: 1)

        XCTAssertEqual(context.viewModel.selectedID, 1)
    }

    func testNextPageFailureKeepsCursorAndRetrySucceeds() async throws {
        let values = (1...65).map {
            inspiration(id: Int64($0), updatedAt: Int64($0))
        }
        let context = makeContext(items: values)
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.store.pageFailuresRemaining = 1

        context.viewModel.loadNextPage()
        try await waitUntil {
            context.viewModel.feedback?.kind == .loadMoreError
        }
        XCTAssertEqual(context.viewModel.items.count, 50)
        XCTAssertTrue(context.viewModel.canLoadMore)

        context.viewModel.loadNextPage()
        try await waitUntil { context.viewModel.items.count == 65 }
        XCTAssertNil(context.viewModel.feedback)
        XCTAssertFalse(context.viewModel.canLoadMore)
    }

    func testInitialLoadFailureCanRetryWithoutShowingFalseEmptyState() async throws {
        let context = makeContext(items: [inspiration(id: 1)])
        context.store.pageFailuresRemaining = 1

        context.viewModel.start()
        try await waitUntil {
            context.viewModel.feedback?.kind == .error
                && !context.viewModel.hasPendingOperation
        }
        XCTAssertFalse(context.viewModel.isReady)
        XCTAssertTrue(context.viewModel.items.isEmpty)

        context.viewModel.retryInitialLoad()
        try await waitUntil { context.viewModel.isReady }
        XCTAssertEqual(context.viewModel.items.map(\.id), [1])
    }

    func testOpenLoadsDetailRequestsExpansionAndDebounceSavesLatestSnapshot() async throws {
        let original = inspiration(id: 1, title: "原标题", body: "原正文", updatedAt: 10)
        let context = makeContext(items: [original], debounceNanoseconds: 20_000_000)
        var expansionCount = 0
        context.viewModel.onRequestExpand = { expansionCount += 1 }
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.viewModel.detailTitle = "中间标题"
        context.viewModel.detailTitle = "最终标题"
        context.viewModel.detailBody = "最终正文\n第二行"
        try await waitUntil {
            context.store.item(id: 1)?.title == "最终标题"
                && context.store.item(id: 1)?.body == "最终正文\n第二行"
        }

        XCTAssertEqual(expansionCount, 1)
        XCTAssertEqual(context.viewModel.screen, .detail)
        XCTAssertEqual(context.store.textUpdates.count, 1)
        XCTAssertNil(context.viewModel.feedback)
    }

    func testSearchCanOpenDetailOutsideLoadedFirstPageByExactID() async throws {
        let values = (1...65).map {
            inspiration(id: Int64($0), updatedAt: Int64($0))
        }
        let context = makeContext(items: values)
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        XCTAssertFalse(context.viewModel.items.contains(where: { $0.id == 1 }))

        XCTAssertTrue(context.viewModel.openFromSearch(identifier: 1))
        try await waitUntil {
            context.viewModel.detailInspiration?.id == 1
                && !context.viewModel.isDetailLoading
        }

        XCTAssertEqual(context.viewModel.screen, .detail)
        XCTAssertEqual(context.viewModel.detailTitle, "标题 1")
    }

    func testDismissalCancelsAStaleDetailReactivationRead() async throws {
        let context = makeContext(
            items: [inspiration(id: 1, title: "可信标题")]
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.store.replace(inspiration(id: 1, title: "外部新标题"))
        context.store.detailDelayNanoseconds = 40_000_000

        context.viewModel.activate()
        XCTAssertTrue(context.viewModel.isDetailLoading)
        context.viewModel.resetForPanelDismissal()
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(context.viewModel.screen, .list)
        XCTAssertFalse(context.viewModel.isDetailLoading)
        XCTAssertEqual(context.viewModel.detailTitle, "可信标题")
    }

    func testMissingDetailReturnsToListAndRemovesStaleRow() async throws {
        let context = makeContext(items: [inspiration(id: 1)])
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.store.remove(id: 1)

        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.feedback?.kind == .error }

        XCTAssertEqual(context.viewModel.screen, .list)
        XCTAssertTrue(context.viewModel.items.isEmpty)
        XCTAssertNil(context.viewModel.selectedID)
    }

    func testCommandSaveFlushesImmediatelyAndShowsTemporaryFeedback() async throws {
        let context = makeContext(
            items: [inspiration(id: 1)],
            debounceNanoseconds: 1_000_000_000,
            savedFeedbackNanoseconds: 20_000_000
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.viewModel.detailBody = "立即保存"

        context.viewModel.commandSave()
        try await waitUntil { context.viewModel.feedback?.kind == .saved }
        XCTAssertEqual(context.store.item(id: 1)?.body, "立即保存")
        try await waitUntil { context.viewModel.feedback == nil }
    }

    func testFailedReturnSaveKeepsDetailAndRetryCanLeave() async throws {
        let context = makeContext(items: [inspiration(id: 1)])
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.store.failTextUpdates = true
        context.viewModel.detailTitle = "不能丢失"

        context.viewModel.returnToList()
        try await waitUntil { context.viewModel.feedback?.kind == .error }
        XCTAssertEqual(context.viewModel.screen, .detail)
        XCTAssertEqual(context.viewModel.detailTitle, "不能丢失")

        context.store.failTextUpdates = false
        context.viewModel.returnToList()
        try await waitUntil { context.viewModel.screen == .list }
        XCTAssertEqual(context.store.item(id: 1)?.title, "不能丢失")
        XCTAssertEqual(context.viewModel.selectedID, 1)
    }

    func testCategoryChangeFlushesTextFirstAndMarksUserSource() async throws {
        let context = makeContext(
            items: [inspiration(id: 1, category: .idea, categorySource: .fallback)],
            debounceNanoseconds: 1_000_000_000
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.viewModel.detailBody = "分类前先保存的正文"

        context.viewModel.chooseCategory(.article)
        try await waitUntil { !context.viewModel.isSavingCategory }

        let stored = try XCTUnwrap(context.store.item(id: 1))
        XCTAssertEqual(stored.body, "分类前先保存的正文")
        XCTAssertEqual(stored.category, .article)
        XCTAssertEqual(stored.categorySource, .user)
        XCTAssertEqual(context.store.events, ["update_text", "update_category"])
    }

    func testSameCategoryDoesNotWrite() async throws {
        let context = makeContext(
            items: [inspiration(id: 1, category: .idea, categorySource: .fallback)]
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }

        context.viewModel.chooseCategory(.idea)
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(context.store.categoryUpdates.count, 0)
        XCTAssertEqual(context.store.item(id: 1)?.categorySource, .fallback)
    }

    func testCategoryFailureRestoresSavedSelectionAndKeepsDetail() async throws {
        let context = makeContext(items: [inspiration(id: 1, category: .idea)])
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.store.failCategoryUpdates = true

        context.viewModel.chooseCategory(.product)
        try await waitUntil { context.viewModel.feedback?.kind == .error }

        XCTAssertEqual(context.viewModel.screen, .detail)
        XCTAssertEqual(context.viewModel.detailCategory, .idea)
        XCTAssertEqual(context.store.item(id: 1)?.category, .idea)
    }

    func testCategorySaveCompletesCleanlyAfterPanelDismissal() async throws {
        let context = makeContext(items: [inspiration(id: 1, category: .idea)])
        context.store.categoryDelayNanoseconds = 40_000_000
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }

        context.viewModel.chooseCategory(.work)
        XCTAssertTrue(context.viewModel.isSavingCategory)
        context.viewModel.resetForPanelDismissal()
        try await waitUntil { !context.viewModel.isSavingCategory }

        XCTAssertEqual(context.viewModel.screen, .list)
        XCTAssertEqual(context.store.item(id: 1)?.category, .work)
        XCTAssertEqual(context.store.item(id: 1)?.categorySource, .user)
        XCTAssertFalse(context.viewModel.hasPendingSave)
    }

    func testDeleteWaitsForStoreThenSelectsAdjacentAndUndoRestoresExactRecord() async throws {
        let newest = inspiration(
            id: 2,
            title: "恢复我",
            body: "完整正文",
            category: .work,
            categorySource: .user,
            updatedAt: 20
        )
        let oldest = inspiration(id: 1, updatedAt: 10)
        let context = makeContext(items: [newest, oldest])
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.canUndo }
        XCTAssertEqual(context.viewModel.items.map(\.id), [1])
        XCTAssertEqual(context.viewModel.selectedID, 1)
        XCTAssertEqual(context.viewModel.feedback?.kind, .deleted)

        context.viewModel.undoDeletion()
        try await waitUntil { context.viewModel.items.contains(newest) }
        XCTAssertEqual(context.store.item(id: 2), newest)
        XCTAssertEqual(context.viewModel.selectedID, 2)
        XCTAssertFalse(context.viewModel.canUndo)
    }

    func testDeleteRefillsOneRowWhenAnotherPageExists() async throws {
        let context = makeContext(
            items: [
                inspiration(id: 3, updatedAt: 3),
                inspiration(id: 2, updatedAt: 2),
                inspiration(id: 1, updatedAt: 1)
            ],
            pageLimit: 2
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        XCTAssertEqual(context.viewModel.items.map(\.id), [3, 2])

        context.viewModel.deleteSelected()
        try await waitUntil {
            context.viewModel.canUndo
                && context.viewModel.items.map(\.id) == [2, 1]
        }

        XCTAssertEqual(context.viewModel.selectedID, 2)
        XCTAssertFalse(context.viewModel.canLoadMore)
    }

    func testDeleteFailureLeavesRowAndDoesNotOpenUndoWindow() async throws {
        let original = inspiration(id: 1)
        let context = makeContext(items: [original])
        context.store.failDeletes = true
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.feedback?.kind == .error }

        XCTAssertEqual(context.viewModel.items, [original])
        XCTAssertFalse(context.viewModel.canUndo)
    }

    func testSecondDeleteReplacesUndoSnapshot() async throws {
        let context = makeContext(items: [
            inspiration(id: 2, updatedAt: 2),
            inspiration(id: 1, updatedAt: 1)
        ])
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.items.count == 1 }
        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.items.isEmpty }
        context.viewModel.undoDeletion()
        try await waitUntil { context.viewModel.items.count == 1 }

        XCTAssertNil(context.store.item(id: 2))
        XCTAssertNotNil(context.store.item(id: 1))
    }

    func testUndoExpiresAfterConfiguredWindow() async throws {
        let context = makeContext(
            items: [inspiration(id: 1)],
            undoNanoseconds: 20_000_000
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.canUndo }
        try await waitUntil { !context.viewModel.canUndo }
        XCTAssertNil(context.viewModel.feedback)
    }

    func testPanelDismissalResetsRouteAndStillFlushesLatestEdit() async throws {
        let context = makeContext(
            items: [inspiration(id: 1)],
            debounceNanoseconds: 1_000_000_000
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.viewModel.detailTitle = "收起前修改"

        context.viewModel.resetForPanelDismissal()

        XCTAssertEqual(context.viewModel.screen, .list)
        try await waitUntil { context.store.item(id: 1)?.title == "收起前修改" }
    }

    func testTabChangeFlushesButPreservesDetailRoute() async throws {
        let context = makeContext(
            items: [inspiration(id: 1)],
            debounceNanoseconds: 1_000_000_000
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.viewModel.detailBody = "切标签前保存"
        var completion: Bool?

        context.viewModel.flushBeforeTabChange { completion = $0 }
        try await waitUntil { completion != nil }

        XCTAssertEqual(completion, true)
        XCTAssertEqual(context.viewModel.screen, .detail)
        XCTAssertEqual(context.store.item(id: 1)?.body, "切标签前保存")

        let pageRequestCount = context.store.pageRequests.count
        context.viewModel.activateListPreservingDetail()
        try await waitUntil {
            context.store.pageRequests.count == pageRequestCount + 1
                && !context.viewModel.isInitialLoading
        }
        XCTAssertEqual(context.viewModel.screen, .detail)
        XCTAssertEqual(context.viewModel.detailBody, "切标签前保存")
    }

    func testActivationReloadsLatestDetailWithoutClosingIt() async throws {
        let context = makeContext(items: [inspiration(id: 1, title: "旧标题")])
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.store.replace(
            inspiration(id: 1, title: "外部刷新标题", body: "刷新正文", updatedAt: 99)
        )

        context.viewModel.activate()
        try await waitUntil { context.viewModel.detailTitle == "外部刷新标题" }

        XCTAssertEqual(context.viewModel.screen, .detail)
        XCTAssertEqual(context.viewModel.detailBody, "刷新正文")
    }

    func testTerminationFlushesBeforeLongDebounceExpires() async throws {
        let context = makeContext(
            items: [inspiration(id: 1)],
            debounceNanoseconds: 1_000_000_000
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.openSelected()
        try await waitUntil { context.viewModel.detailFocusRequest == 1 }
        context.viewModel.detailBody = "退出前最后字符"

        let prepared = await context.viewModel.prepareForTermination()
        XCTAssertTrue(prepared)
        XCTAssertEqual(context.store.item(id: 1)?.body, "退出前最后字符")
    }

    private func makeContext(
        items: [Inspiration],
        pageLimit: Int = 50,
        debounceNanoseconds: UInt64 = 10_000_000,
        undoNanoseconds: UInt64 = 3_000_000_000,
        savedFeedbackNanoseconds: UInt64 = 800_000_000
    ) -> InspirationLibraryTestContext {
        let store = FakeInspirationLibraryStore(items: items)
        let viewModel = InspirationLibraryViewModel(
            store: store,
            pageLimit: pageLimit,
            debounceNanoseconds: debounceNanoseconds,
            undoNanoseconds: undoNanoseconds,
            savedFeedbackNanoseconds: savedFeedbackNanoseconds,
            nowUTCms: { 1_000 }
        )
        return InspirationLibraryTestContext(viewModel: viewModel, store: store)
    }

    private func inspiration(
        id: Int64,
        title: String? = nil,
        body: String? = nil,
        category: InspirationCategory = .idea,
        categorySource: ValueSource = .fallback,
        updatedAt: Int64 = 1
    ) -> Inspiration {
        Inspiration(
            id: id,
            title: title ?? "标题 \(id)",
            body: body ?? "正文 \(id)",
            category: category,
            categorySource: categorySource,
            createdAtUTCms: id,
            updatedAtUTCms: updatedAt,
            source: .manual
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - started > timeoutNanoseconds {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
private struct InspirationLibraryTestContext {
    let viewModel: InspirationLibraryViewModel
    let store: FakeInspirationLibraryStore
}

private enum FakeInspirationLibraryError: Error {
    case failed
}

@MainActor
private final class FakeInspirationLibraryStore: InspirationLibraryStoring {
    private var itemsByID: [Int64: Inspiration]
    private(set) var pageRequests: [InspirationPageCursor?] = []
    private(set) var textUpdates: [(Int64, String, String)] = []
    private(set) var categoryUpdates: [(Int64, InspirationCategory)] = []
    private(set) var events: [String] = []
    var failTextUpdates = false
    var failCategoryUpdates = false
    var failDeletes = false
    var failRestores = false
    var pageDelayNanoseconds: UInt64 = 0
    var categoryDelayNanoseconds: UInt64 = 0
    var detailDelayNanoseconds: UInt64 = 0
    var pageFailuresRemaining = 0

    init(items: [Inspiration]) {
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    func item(id: Int64) -> Inspiration? {
        itemsByID[id]
    }

    func replace(_ inspiration: Inspiration) {
        itemsByID[inspiration.id] = inspiration
    }

    func remove(id: Int64) {
        itemsByID[id] = nil
    }

    func listInspirationsPage(
        after cursor: InspirationPageCursor?,
        limit: Int
    ) async throws -> InspirationPage {
        pageRequests.append(cursor)
        if pageDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: pageDelayNanoseconds)
        }
        if pageFailuresRemaining > 0 {
            pageFailuresRemaining -= 1
            throw FakeInspirationLibraryError.failed
        }
        let sorted = itemsByID.values.sorted {
            ($0.updatedAtUTCms, $0.id) > ($1.updatedAtUTCms, $1.id)
        }
        let filtered = sorted.filter { item in
            guard let cursor else { return true }
            return item.updatedAtUTCms < cursor.updatedAtUTCms
                || (item.updatedAtUTCms == cursor.updatedAtUTCms && item.id < cursor.id)
        }
        let bounded = min(max(limit, 1), 100)
        let values = Array(filtered.prefix(bounded))
        let hasMore = filtered.count > values.count
        let nextCursor = hasMore
            ? values.last.map {
                InspirationPageCursor(updatedAtUTCms: $0.updatedAtUTCms, id: $0.id)
            }
            : nil
        return InspirationPage(items: values, nextCursor: nextCursor)
    }

    func inspiration(id: Int64) async throws -> Inspiration {
        if detailDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: detailDelayNanoseconds)
        }
        guard let item = itemsByID[id] else {
            throw PersistenceError.inspirationNotFound(id: id)
        }
        return item
    }

    func updateInspirationText(
        id: Int64,
        title: String,
        body: String,
        updatedAtUTCms: Int64
    ) async throws -> Inspiration {
        events.append("update_text")
        textUpdates.append((id, title, body))
        if failTextUpdates {
            throw FakeInspirationLibraryError.failed
        }
        guard let existing = itemsByID[id] else {
            throw PersistenceError.inspirationNotFound(id: id)
        }
        if existing.title == title, existing.body == body {
            return existing
        }
        let updated = Inspiration(
            id: existing.id,
            title: title,
            body: body,
            category: existing.category,
            categorySource: existing.categorySource,
            createdAtUTCms: existing.createdAtUTCms,
            updatedAtUTCms: max(updatedAtUTCms, existing.updatedAtUTCms + 1),
            source: existing.source
        )
        itemsByID[id] = updated
        return updated
    }

    func updateInspirationCategory(
        id: Int64,
        category: InspirationCategory,
        updatedAtUTCms: Int64
    ) async throws -> Inspiration {
        events.append("update_category")
        categoryUpdates.append((id, category))
        if categoryDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: categoryDelayNanoseconds)
        }
        if failCategoryUpdates {
            throw FakeInspirationLibraryError.failed
        }
        guard let existing = itemsByID[id] else {
            throw PersistenceError.inspirationNotFound(id: id)
        }
        if existing.category == category {
            return existing
        }
        let updated = Inspiration(
            id: existing.id,
            title: existing.title,
            body: existing.body,
            category: category,
            categorySource: .user,
            createdAtUTCms: existing.createdAtUTCms,
            updatedAtUTCms: max(updatedAtUTCms, existing.updatedAtUTCms + 1),
            source: existing.source
        )
        itemsByID[id] = updated
        return updated
    }

    func deleteInspiration(id: Int64) async throws -> Inspiration {
        if failDeletes {
            throw FakeInspirationLibraryError.failed
        }
        guard let removed = itemsByID.removeValue(forKey: id) else {
            throw PersistenceError.inspirationNotFound(id: id)
        }
        return removed
    }

    func restoreInspiration(_ inspiration: Inspiration) async throws -> Inspiration {
        if failRestores {
            throw FakeInspirationLibraryError.failed
        }
        itemsByID[inspiration.id] = inspiration
        return inspiration
    }
}
