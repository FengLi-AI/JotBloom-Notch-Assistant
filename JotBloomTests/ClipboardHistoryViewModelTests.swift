import Foundation
import XCTest
@testable import JotBloomCore

@MainActor
final class ClipboardHistoryViewModelTests: XCTestCase {
    func testStartLoadsNewestItemAndArrowSelectionStopsAtBounds() async throws {
        let items = [
            ClipboardTestFixtures.item(id: 2, text: "new", copiedAt: 2),
            ClipboardTestFixtures.item(id: 1, text: "old", copiedAt: 1)
        ]
        let context = makeContext(items: items)
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        XCTAssertEqual(context.viewModel.selectedID, 2)
        context.viewModel.moveSelection(by: 1)
        XCTAssertEqual(context.viewModel.selectedID, 1)
        context.viewModel.moveSelection(by: 1)
        XCTAssertEqual(context.viewModel.selectedID, 1)
        context.viewModel.moveSelection(by: -1)
        context.viewModel.moveSelection(by: -1)
        XCTAssertEqual(context.viewModel.selectedID, 2)
    }

    func testClickStyleCopyWritesExactTextAdvancesBaselineAndCollapses() async throws {
        let item = ClipboardTestFixtures.item(
            id: 1,
            text: " exact text \n",
            copiedAt: 1
        )
        let context = makeContext(items: [item])
        var baseline: Int?
        var collapseCount = 0
        context.viewModel.onPasteboardWritten = { baseline = $0 }
        context.viewModel.onRequestCollapse = { collapseCount += 1 }
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.copySelected(collapseAfterCopy: true)
        try await waitUntil { context.writer.text == " exact text \n" }

        XCTAssertEqual(baseline, context.writer.changeCount)
        XCTAssertEqual(collapseCount, 1)
        XCTAssertNil(context.viewModel.copiedItemID)
        XCTAssertNil(context.viewModel.feedback)
    }

    func testCommandCopyKeepsPanelOpenAndFeedbackExpires() async throws {
        let item = ClipboardTestFixtures.item(id: 1, text: "copy", copiedAt: 1)
        let context = makeContext(
            items: [item],
            copiedFeedbackNanoseconds: 30_000_000
        )
        var collapseCount = 0
        context.viewModel.onRequestCollapse = { collapseCount += 1 }
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.copySelected(collapseAfterCopy: false)
        try await waitUntil { context.viewModel.feedback?.kind == .copied }
        XCTAssertEqual(collapseCount, 0)
        XCTAssertEqual(context.viewModel.copiedItemID, item.id)
        try await waitUntil { context.viewModel.feedback == nil }
        XCTAssertNil(context.viewModel.copiedItemID)
    }

    func testFailedCopyDoesNotRequestCollapse() async throws {
        let item = ClipboardTestFixtures.item(id: 1, text: "copy", copiedAt: 1)
        let context = makeContext(items: [item])
        context.writer.shouldFail = true
        var collapseCount = 0
        context.viewModel.onRequestCollapse = { collapseCount += 1 }
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.copySelected(collapseAfterCopy: true)
        try await waitUntil { context.viewModel.feedback?.kind == .error }

        XCTAssertEqual(collapseCount, 0)
        XCTAssertNil(context.writer.text)
    }

    func testImageCopyUsesStoredOriginalData() async throws {
        let identifier = UUID().uuidString.uppercased()
        let item = ClipboardTestFixtures.item(
            id: 1,
            type: .image,
            text: nil,
            imageFileName: "\(identifier).png",
            thumbnailFileName: "\(identifier)-thumb.png",
            byteCount: 3,
            sha256: String(repeating: "a", count: 64),
            width: 3,
            height: 1,
            copiedAt: 1
        )
        let context = makeContext(items: [item], imageData: Data([1, 2, 3]))
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.copySelected(collapseAfterCopy: false)
        try await waitUntil { context.writer.pngData != nil }
        XCTAssertEqual(context.writer.pngData, Data([1, 2, 3]))
    }

    func testUnavailableImageKeepsExistingPasteboardAndPanelOpen() async throws {
        let item = imageItem(id: 1, copiedAt: 1)
        let context = makeContext(items: [item])
        _ = try context.writer.writeText("existing clipboard value")
        let initialChangeCount = context.writer.changeCount
        await context.service.setImageAvailable(false)
        var collapseCount = 0
        context.viewModel.onRequestCollapse = { collapseCount += 1 }
        context.viewModel.start()
        try await waitUntil {
            context.viewModel.isReady
                && context.viewModel.unavailableImageIDs.contains(item.id)
        }

        context.viewModel.copySelected(collapseAfterCopy: true)

        XCTAssertEqual(context.writer.text, "existing clipboard value")
        XCTAssertNil(context.writer.pngData)
        XCTAssertEqual(context.writer.changeCount, initialChangeCount)
        XCTAssertEqual(collapseCount, 0)
        XCTAssertEqual(context.viewModel.feedback?.kind, .error)
    }

    func testDeleteFailureDoesNotOptimisticallyRemoveRow() async throws {
        let item = ClipboardTestFixtures.item(id: 1, copiedAt: 1)
        let context = makeContext(items: [item])
        await context.service.setDeleteShouldFail(true)
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.feedback?.kind == .error }

        XCTAssertEqual(context.viewModel.items, [item])
        XCTAssertFalse(context.viewModel.canUndo)
    }

    func testSecondMutationIsIgnoredUntilDeletionCommits() async throws {
        let item = ClipboardTestFixtures.item(id: 1, text: "keep consistent", copiedAt: 1)
        let context = makeContext(items: [item])
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.deleteSelected()
        context.viewModel.copySelected(collapseAfterCopy: false)
        try await waitUntil { context.viewModel.items.isEmpty }

        XCTAssertNil(context.writer.text)
        XCTAssertTrue(context.viewModel.canUndo)
    }

    func testRealtimeReloadPreservesSelectionAndChoosesAdjacentIfRemoved() async throws {
        let newest = ClipboardTestFixtures.item(id: 3, text: "three", copiedAt: 3)
        let middle = ClipboardTestFixtures.item(id: 2, text: "two", copiedAt: 2)
        let oldest = ClipboardTestFixtures.item(id: 1, text: "one", copiedAt: 1)
        let context = makeContext(items: [newest, middle, oldest])
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.select(middle.id)
        let added = ClipboardTestFixtures.item(id: 4, text: "four", copiedAt: 4)
        await context.service.replaceItems([added, newest, middle, oldest])

        context.viewModel.handleCaptureOutcome(.inserted(added))
        try await waitUntil { context.viewModel.items.first?.id == added.id }
        XCTAssertEqual(context.viewModel.selectedID, middle.id)

        await context.service.replaceItems([added, newest, oldest])
        context.viewModel.handleCaptureOutcome(.refreshed(newest))
        try await waitUntil { !context.viewModel.items.contains(middle) }
        XCTAssertEqual(context.viewModel.selectedID, oldest.id)
    }

    func testDeleteThenUndoRestoresLatestRecord() async throws {
        let item = ClipboardTestFixtures.item(id: 1, copiedAt: 1)
        let context = makeContext(items: [item])
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.items.isEmpty }
        XCTAssertTrue(context.viewModel.canUndo)
        XCTAssertEqual(context.viewModel.feedback?.kind, .deleted)

        context.viewModel.undoDeletion()
        try await waitUntil { context.viewModel.items == [item] }
        XCTAssertFalse(context.viewModel.canUndo)
        let restoreCount = await context.service.restoreCount()
        XCTAssertEqual(restoreCount, 1)
    }

    func testUndoExpiryFinalizesImageOnlyAfterWindow() async throws {
        let item = imageItem(id: 1, copiedAt: 1)
        let context = makeContext(
            items: [item],
            undoDurationNanoseconds: 20_000_000
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.canUndo }
        let beforeExpiry = await context.service.finalizedIDs()
        XCTAssertEqual(beforeExpiry, [])
        try await waitUntil {
            await context.service.finalizedIDs() == [item.id]
        }
        XCTAssertFalse(context.viewModel.canUndo)
    }

    func testSecondDeletionExpiresPreviousUndoSnapshot() async throws {
        let first = ClipboardTestFixtures.item(id: 2, text: "first", copiedAt: 2)
        let second = ClipboardTestFixtures.item(id: 1, text: "second", copiedAt: 1)
        let context = makeContext(
            items: [first, second],
            undoDurationNanoseconds: 1_000_000_000
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }

        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.items.count == 1 }
        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.items.isEmpty }

        let finalized = await context.service.finalizedIDs()
        XCTAssertEqual(finalized, [first.id])
        XCTAssertTrue(context.viewModel.canUndo)
    }

    func testTerminationFinalizesPendingDeletion() async throws {
        let item = imageItem(id: 1, copiedAt: 1)
        let context = makeContext(
            items: [item],
            undoDurationNanoseconds: 1_000_000_000
        )
        context.viewModel.start()
        try await waitUntil { context.viewModel.isReady }
        context.viewModel.deleteSelected()
        try await waitUntil { context.viewModel.canUndo }

        await context.viewModel.prepareForTermination()

        let finalized = await context.service.finalizedIDs()
        XCTAssertEqual(finalized, [item.id])
        XCTAssertFalse(context.viewModel.canUndo)
    }

    private func makeContext(
        items: [ClipboardItem],
        imageData: Data = Data([9]),
        undoDurationNanoseconds: UInt64 = 3_000_000_000,
        copiedFeedbackNanoseconds: UInt64 = 800_000_000
    ) -> ViewModelTestContext {
        let service = FakeClipboardService(items: items, imageData: imageData)
        let writer = FakeClipboardWriter()
        let viewModel = ClipboardHistoryViewModel(
            service: service,
            pasteboardWriter: writer,
            undoDurationNanoseconds: undoDurationNanoseconds,
            copiedFeedbackNanoseconds: copiedFeedbackNanoseconds,
            nowUTCms: { 100 }
        )
        return ViewModelTestContext(
            viewModel: viewModel,
            service: service,
            writer: writer
        )
    }

    private func imageItem(id: Int64, copiedAt: Int64) -> ClipboardItem {
        let identifier = UUID().uuidString.uppercased()
        return ClipboardTestFixtures.item(
            id: id,
            type: .image,
            text: nil,
            imageFileName: "\(identifier).png",
            thumbnailFileName: "\(identifier)-thumb.png",
            byteCount: 1,
            sha256: String(repeating: "f", count: 64),
            width: 1,
            height: 1,
            copiedAt: copiedAt
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

private struct ViewModelTestContext {
    let viewModel: ClipboardHistoryViewModel
    let service: FakeClipboardService
    let writer: FakeClipboardWriter
}

private enum FakeClipboardError: Error {
    case deleteFailed
    case writeFailed
}

private actor FakeClipboardService: ClipboardHistoryServicing {
    private var items: [ClipboardItem]
    private let imageDataValue: Data
    private var shouldFailDelete = false
    private var imageAvailable = true
    private var restoreCallCount = 0
    private var finalized: [Int64] = []

    init(items: [ClipboardItem], imageData: Data) {
        self.items = items
        imageDataValue = imageData
    }

    func setDeleteShouldFail(_ value: Bool) {
        shouldFailDelete = value
    }

    func setImageAvailable(_ value: Bool) {
        imageAvailable = value
    }

    func restoreCount() -> Int {
        restoreCallCount
    }

    func finalizedIDs() -> [Int64] {
        finalized
    }

    func replaceItems(_ newItems: [ClipboardItem]) {
        items = newItems
    }

    func prepare(nowUTCms: Int64) async throws -> [ClipboardItem] {
        items
    }

    func capture(_ snapshot: ClipboardSnapshot) async throws -> ClipboardCaptureOutcome {
        .skipped
    }

    func listItems() async throws -> [ClipboardItem] {
        items.sorted {
            ($0.copiedAtUTCms, $0.id) > ($1.copiedAtUTCms, $1.id)
        }
    }

    func imageData(for item: ClipboardItem) async throws -> Data {
        imageDataValue
    }

    func thumbnailURL(for item: ClipboardItem) async -> URL? {
        nil
    }

    func isImageAvailable(for item: ClipboardItem) async -> Bool {
        imageAvailable
    }

    func delete(id: Int64) async throws -> ClipboardItem? {
        if shouldFailDelete {
            throw FakeClipboardError.deleteFailed
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return items.remove(at: index)
    }

    func restore(_ item: ClipboardItem) async throws -> ClipboardItem {
        restoreCallCount += 1
        if let existing = items.first(where: {
            $0.contentType == item.contentType
                && $0.textContent == item.textContent
                && $0.imageSHA256 == item.imageSHA256
        }) {
            return existing
        }
        items.append(item)
        return item
    }

    func finalizeDeletion(_ item: ClipboardItem) async {
        finalized.append(item.id)
    }
}

@MainActor
private final class FakeClipboardWriter: ClipboardWriting {
    private(set) var text: String?
    private(set) var pngData: Data?
    private(set) var changeCount = 0
    var shouldFail = false

    func writeText(_ text: String) throws -> Int {
        if shouldFail {
            throw FakeClipboardError.writeFailed
        }
        self.text = text
        changeCount += 1
        return changeCount
    }

    func writePNGData(_ data: Data) throws -> Int {
        if shouldFail {
            throw FakeClipboardError.writeFailed
        }
        pngData = data
        changeCount += 1
        return changeCount
    }
}
