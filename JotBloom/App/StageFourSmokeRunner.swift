#if DEBUG
import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import JotBloomCore

struct StageFourSmokeBootstrap {
    let dataDirectoryURL: URL
    let seededIDs: [Int64]
    let productionDirectoryURL: URL
    let productionSnapshotBefore: DebugDirectorySnapshot
    let generalPasteboardChangeCountBefore: Int
}

@MainActor
final class StageFourSmokeRunner {
    private let bootstrap: StageFourSmokeBootstrap
    private let store: JotBloomStore
    private let namedPasteboard: NSPasteboard
    private let inputViewModel: InspirationInputViewModel
    private let libraryViewModel: InspirationLibraryViewModel
    private let coordinator: PanelVisibilityCoordinator
    private let panelController: PanelController

    init(
        bootstrap: StageFourSmokeBootstrap,
        store: JotBloomStore,
        namedPasteboard: NSPasteboard,
        inputViewModel: InspirationInputViewModel,
        libraryViewModel: InspirationLibraryViewModel,
        coordinator: PanelVisibilityCoordinator,
        panelController: PanelController
    ) {
        self.bootstrap = bootstrap
        self.store = store
        self.namedPasteboard = namedPasteboard
        self.inputViewModel = inputViewModel
        self.libraryViewModel = libraryViewModel
        self.coordinator = coordinator
        self.panelController = panelController
    }

    func run() {
        Task { [self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                let result = try await execute()
                let elapsedMilliseconds = (
                    ProcessInfo.processInfo.systemUptime - startedAt
                ) * 1_000
                print(
                    "JOTBLOOM_STAGE4_SMOKE "
                        + "success=\(result.allPassed) "
                        + "schema_current=\(result.schemaV2) "
                        + "seeded_65=\(result.seeded65) "
                        + "page_50_15=\(result.page50And15) "
                        + "panel_slice_ready=\(result.panelSliceReady) "
                        + "enter_detail=\(result.enteredDetail) "
                        + "auto_expanded=\(result.autoExpanded) "
                        + "debounce_saved=\(result.debounceSaved) "
                        + "category_user=\(result.categoryMarkedUser) "
                        + "escape_returned=\(result.escapeReturned) "
                        + "delete_undo_exact=\(result.deleteUndoExact) "
                        + "delete_expired=\(result.deleteExpired) "
                        + "reopen_restored=\(result.reopenRestored) "
                        + "recent_synced=\(result.recentSynced) "
                        + "panel_reset=\(result.panelReset) "
                        + "named_pasteboard=\(result.namedPasteboard) "
                        + "general_pasteboard_untouched=\(result.generalPasteboardUntouched) "
                        + "production_data_untouched=\(result.productionDataUntouched) "
                        + "performance_target=\(result.performance.targetPassed) "
                        + "performance_count=\(result.performance.itemCount) "
                        + "performance_loaded_count=\(result.performance.loadedItemCount) "
                        + String(
                            format: "page50_median_ms=%.3f ",
                            result.performance.firstPageMedianMilliseconds
                        )
                        + String(
                            format: "page50_p95_ms=%.3f ",
                            result.performance.firstPageP95Milliseconds
                        )
                        + String(
                            format: "page1000_total_ms=%.3f ",
                            result.performance.allPagesMilliseconds
                        )
                        + String(
                            format: "page_p95_ms=%.3f ",
                            result.performance.pageP95Milliseconds
                        )
                        + String(
                            format: "text_update_p95_ms=%.3f ",
                            result.performance.textUpdateP95Milliseconds
                        )
                        + String(
                            format: "category_update_p95_ms=%.3f ",
                            result.performance.categoryUpdateP95Milliseconds
                        )
                        + String(
                            format: "resident_mb=%.3f ",
                            result.performance.residentMegabytes
                        )
                        + String(
                            format: "physical_footprint_mb=%.3f ",
                            result.performance.physicalFootprintMegabytes
                        )
                        + String(format: "elapsed_ms=%.3f", elapsedMilliseconds)
                )
            } catch {
                print(
                    "JOTBLOOM_STAGE4_SMOKE "
                        + "success=false error=true named_pasteboard=true"
                )
            }
            NSApp.terminate(nil)
        }
    }

    private func execute() async throws -> StageFourSmokeResult {
        panelController.debugSetAutomaticDismissalEnabled(false)
        let schemaV2 = try store.schemaVersionSynchronously() == DatabaseMigrator.currentVersion
        let firstPage = try store.listInspirationsPageSynchronously()
        let secondPage = try store.listInspirationsPageSynchronously(
            after: firstPage.nextCursor
        )
        let seededIDs = firstPage.items.map(\.id) + secondPage.items.map(\.id)
        let seeded65 = seededIDs.count == 65
            && Set(seededIDs) == Set(bootstrap.seededIDs)
        let page50And15 = firstPage.items.count == 50
            && secondPage.items.count == 15
            && firstPage.hasMore
            && !secondPage.hasMore
            && Set(seededIDs).count == 65
            && isStrictlyDescending(firstPage.items + secondPage.items)

        let modelsReady = await waitUntil {
            self.inputViewModel.isReady && self.libraryViewModel.isReady
        }
        let generalPasteboardUntouched = NSPasteboard.general.changeCount
            == bootstrap.generalPasteboardChangeCountBefore
        coordinator.show()
        panelController.debugSelectInspirationLibrary()
        let panelReady = await waitUntil {
            let snapshot = self.panelController.debugSnapshot
            return snapshot.isVisible
                && snapshot.isKey
                && snapshot.selectedTab == PanelTab.inspirationLibrary.rawValue
                && snapshot.inspirationLibraryItemCount == 50
                && !self.libraryViewModel.isInitialLoading
        }
        let panelSliceReady = modelsReady && panelReady

        libraryViewModel.loadNextPage()
        let loadedAll = await waitUntil {
            self.libraryViewModel.items.count == 65
                && !self.libraryViewModel.canLoadMore
        }
        let loadedIDs = libraryViewModel.items.map(\.id)
        let allRowsUnique = loadedAll
            && Set(loadedIDs).count == 65
            && Set(loadedIDs) == Set(bootstrap.seededIDs)

        panelController.debugSendKeyDown(keyCode: UInt16(kVK_Return))
        let enteredDetail = await waitUntil {
            self.libraryViewModel.screen == .detail
                && self.libraryViewModel.detailInspiration != nil
                && !self.libraryViewModel.isDetailLoading
        }
        let editedID = libraryViewModel.detailInspiration?.id
        let autoExpanded = enteredDetail
            && panelController.debugSnapshot.isExpanded

        let editedTitle = "阶段四标题 '🌱\0"
        let editedBody = "阶段四正文 %\n第二行\0尾"
        libraryViewModel.detailTitle = editedTitle
        libraryViewModel.detailBody = editedBody
        let debounceSaved = await waitUntil {
            guard let editedID,
                  let stored = try? self.store.inspirationSynchronously(id: editedID) else {
                return false
            }
            return stored.title == editedTitle
                && stored.body == editedBody
                && !self.libraryViewModel.isSavingText
                && !self.libraryViewModel.hasPendingSave
        }

        libraryViewModel.chooseCategory(.product)
        let categoryMarkedUser = await waitUntil {
            guard let editedID,
                  let stored = try? self.store.inspirationSynchronously(id: editedID) else {
                return false
            }
            return stored.category == .product
                && stored.categorySource == .user
                && stored.title == editedTitle
                && stored.body == editedBody
                && !self.libraryViewModel.isSavingCategory
                && !self.libraryViewModel.hasPendingSave
        }

        let escapeWasHandled = panelController.debugPerformKeyEquivalent(
            keyCode: UInt16(kVK_Escape)
        )
        let didReturnFromDetail = await waitUntil {
            self.libraryViewModel.screen == .list
                && self.libraryViewModel.selectedID == editedID
                && !self.libraryViewModel.isInitialLoading
                && !self.libraryViewModel.hasPendingOperation
        }
        let escapeReturned = escapeWasHandled && didReturnFromDetail

        libraryViewModel.moveSelection(by: 1)
        guard let deletionID = libraryViewModel.selectedID,
              deletionID != editedID else {
            throw StageFourSmokeError.missingDeletionTarget
        }
        let deletionSnapshot = try store.inspirationSynchronously(id: deletionID)
        let deleteHandled = panelController.debugPerformKeyEquivalent(
            keyCode: UInt16(kVK_Delete),
            modifiers: .command
        )
        let deletionCompleted = await waitUntil {
            (try? self.store.inspirationSynchronously(id: deletionID)) == nil
                && self.libraryViewModel.canUndo
                && !self.libraryViewModel.hasPendingOperation
        }
        let deleted = deleteHandled && deletionCompleted
        let undoHandled = panelController.debugPerformKeyEquivalent(
            keyCode: UInt16(kVK_ANSI_Z),
            modifiers: .command
        )
        let restorationCompleted = await waitUntil {
            (try? self.store.inspirationSynchronously(id: deletionID))
                == deletionSnapshot
                && !self.libraryViewModel.canUndo
                && !self.libraryViewModel.hasPendingOperation
        }
        let restoredExactly = undoHandled && restorationCompleted
        let deleteUndoExact = deleted && restoredExactly

        let secondDeleteHandled = panelController.debugPerformKeyEquivalent(
            keyCode: UInt16(kVK_Delete),
            modifiers: .command
        )
        let secondDeletionCompleted = await waitUntil {
            (try? self.store.inspirationSynchronously(id: deletionID)) == nil
                && self.libraryViewModel.canUndo
                && !self.libraryViewModel.hasPendingOperation
        }
        let deletedAgain = secondDeleteHandled && secondDeletionCompleted
        let undoWindowExpired = await waitUntil(
            timeoutNanoseconds: 4_000_000_000
        ) {
            !self.libraryViewModel.canUndo
        }
        let deleteExpired = deletedAgain
            && undoWindowExpired
            && (try? store.inspirationSynchronously(id: deletionID)) == nil

        let reopened = try JotBloomStore(
            dataDirectoryURL: bootstrap.dataDirectoryURL
        )
        let reopenedFirst = try reopened.listInspirationsPageSynchronously()
        let reopenedSecond = try reopened.listInspirationsPageSynchronously(
            after: reopenedFirst.nextCursor
        )
        let reopenedEdited = editedID.flatMap {
            try? reopened.inspirationSynchronously(id: $0)
        }
        let reopenedDeleted = try? reopened.inspirationSynchronously(
            id: deletionID
        )
        let reopenRestored = try reopened.schemaVersionSynchronously() == DatabaseMigrator.currentVersion
            && reopenedFirst.items.count + reopenedSecond.items.count == 64
            && reopenedEdited?.title == editedTitle
            && reopenedEdited?.body == editedBody
            && reopenedEdited?.category == .product
            && reopenedEdited?.categorySource == .user
            && reopenedDeleted == nil
        reopened.close()

        coordinator.show()
        panelController.debugSelectInspiration()
        let recentSynced = await waitUntil {
            guard let editedID else { return false }
            let snapshot = self.panelController.debugSnapshot
            return snapshot.isVisible
                && snapshot.selectedTab == PanelTab.inspiration.rawValue
                && self.inputViewModel.recentInspirations.contains {
                $0.id == editedID
                    && $0.title == editedTitle
                    && $0.category == .product
                    && $0.categorySource == .user
            }
                && !self.inputViewModel.recentInspirations.contains {
                    $0.id == deletionID
                }
        }

        coordinator.show()
        panelController.debugSelectInspirationLibrary()
        _ = await waitUntil {
            let snapshot = self.panelController.debugSnapshot
            return snapshot.isVisible
                && snapshot.selectedTab == PanelTab.inspirationLibrary.rawValue
                && self.libraryViewModel.screen == .list
        }
        if let editedID {
            libraryViewModel.select(editedID)
        }
        panelController.debugSendKeyDown(keyCode: UInt16(kVK_Return))
        _ = await waitUntil {
            self.libraryViewModel.screen == .detail
                && !self.libraryViewModel.isDetailLoading
        }
        coordinator.hide(restoreFocus: false)
        let hidden = panelController.debugSnapshot
        coordinator.show()
        let shown = panelController.debugSnapshot
        let panelReset = !hidden.isVisible
            && hidden.selectedTab == PanelTab.inspiration.rawValue
            && !hidden.isExpanded
            && hidden.inspirationLibraryScreen
                == String(describing: InspirationLibraryScreen.list)
            && shown.isVisible
            && shown.selectedTab == PanelTab.inspiration.rawValue
            && !shown.isExpanded
        coordinator.hide(restoreFocus: false)

        let performance = try await runPerformanceProbe()
        let namedPasteboard = namedPasteboard.name != .general
        let productionDataUntouched = DebugDirectorySnapshot.capture(
            url: bootstrap.productionDirectoryURL
        ) == bootstrap.productionSnapshotBefore

        return StageFourSmokeResult(
            schemaV2: schemaV2,
            seeded65: seeded65,
            page50And15: page50And15 && allRowsUnique,
            panelSliceReady: panelSliceReady,
            enteredDetail: enteredDetail,
            autoExpanded: autoExpanded,
            debounceSaved: debounceSaved,
            categoryMarkedUser: categoryMarkedUser,
            escapeReturned: escapeReturned,
            deleteUndoExact: deleteUndoExact,
            deleteExpired: deleteExpired,
            reopenRestored: reopenRestored,
            recentSynced: recentSynced,
            panelReset: panelReset,
            namedPasteboard: namedPasteboard,
            generalPasteboardUntouched: generalPasteboardUntouched,
            productionDataUntouched: productionDataUntouched,
            performance: performance
        )
    }

    private func runPerformanceProbe() async throws -> StageFourPerformanceResult {
        let directory = bootstrap.dataDirectoryURL.appendingPathComponent(
            "StageFourPerformance-\(UUID().uuidString)",
            isDirectory: true
        )
        let probeStore = try JotBloomStore(dataDirectoryURL: directory)
        defer {
            probeStore.close()
            try? FileManager.default.removeItem(at: directory)
        }

        for index in 0..<1_000 {
            _ = try probeStore.saveManualInspirationSynchronously(
                ParsedInspiration(
                    title: "性能标题 \(index)",
                    body: "性能正文 \(index)\n🌱"
                ),
                timestampUTCms: Int64(index + 1)
            )
        }

        var firstPageDurations: [Double] = []
        for _ in 0..<30 {
            let startedAt = ProcessInfo.processInfo.systemUptime
            _ = try probeStore.listInspirationsPageSynchronously()
            firstPageDurations.append(milliseconds(since: startedAt))
        }

        var pageDurations: [Double] = []
        var itemCount = 0
        var cursor: InspirationPageCursor?
        let allPagesStartedAt = ProcessInfo.processInfo.systemUptime
        repeat {
            let pageStartedAt = ProcessInfo.processInfo.systemUptime
            let page = try probeStore.listInspirationsPageSynchronously(
                after: cursor
            )
            pageDurations.append(milliseconds(since: pageStartedAt))
            itemCount += page.items.count
            cursor = page.nextCursor
        } while cursor != nil
        let allPagesMilliseconds = milliseconds(since: allPagesStartedAt)

        guard let targetID = try probeStore
            .listInspirationsPageSynchronously(limit: 1)
            .items.first?.id else {
            throw StageFourSmokeError.missingPerformanceTarget
        }
        var textDurations: [Double] = []
        for index in 0..<30 {
            let startedAt = ProcessInfo.processInfo.systemUptime
            _ = try probeStore.updateInspirationTextSynchronously(
                id: targetID,
                title: "更新标题 \(index)",
                body: "更新正文 \(index)",
                updatedAtUTCms: Int64(index + 2_000)
            )
            textDurations.append(milliseconds(since: startedAt))
        }

        let categories: [InspirationCategory] = [
            .article,
            .work,
            .product,
            .idea
        ]
        var categoryDurations: [Double] = []
        for index in 0..<30 {
            let startedAt = ProcessInfo.processInfo.systemUptime
            _ = try probeStore.updateInspirationCategorySynchronously(
                id: targetID,
                category: categories[index % categories.count],
                updatedAtUTCms: Int64(index + 3_000)
            )
            categoryDurations.append(milliseconds(since: startedAt))
        }

        let loadedViewModel = InspirationLibraryViewModel(store: probeStore)
        loadedViewModel.start()
        guard await waitUntil(condition: {
            loadedViewModel.isReady && !loadedViewModel.isInitialLoading
        }) else {
            throw StageFourSmokeError.performanceLoadTimedOut
        }
        while loadedViewModel.canLoadMore {
            let previousCount = loadedViewModel.items.count
            loadedViewModel.loadNextPage()
            guard await waitUntil(condition: {
                !loadedViewModel.isLoadingNextPage
                    && loadedViewModel.items.count > previousCount
            }) else {
                throw StageFourSmokeError.performanceLoadTimedOut
            }
        }
        guard let residentBytes = residentMemoryBytes(),
              let footprintBytes = physicalFootprintBytes() else {
            throw StageFourSmokeError.memoryMeasurementFailed
        }

        return StageFourPerformanceResult(
            itemCount: itemCount,
            loadedItemCount: loadedViewModel.items.count,
            firstPageMedianMilliseconds: median(firstPageDurations),
            firstPageP95Milliseconds: p95(firstPageDurations),
            allPagesMilliseconds: allPagesMilliseconds,
            pageP95Milliseconds: p95(pageDurations),
            textUpdateP95Milliseconds: p95(textDurations),
            categoryUpdateP95Milliseconds: p95(categoryDurations),
            residentMegabytes: Double(residentBytes) / 1_048_576,
            physicalFootprintMegabytes: Double(footprintBytes) / 1_048_576
        )
    }

    private func residentMemoryBytes() -> UInt64? {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(information.resident_size)
    }

    private func physicalFootprintBytes() -> UInt64? {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(information.phys_footprint)
    }

    private func isStrictlyDescending(_ items: [Inspiration]) -> Bool {
        zip(items, items.dropFirst()).allSatisfy { left, right in
            (left.updatedAtUTCms, left.id) > (right.updatedAtUTCms, right.id)
        }
    }

    private func milliseconds(since startedAt: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        return sorted[index]
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - startedAt
                > timeoutNanoseconds {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }
}

private enum StageFourSmokeError: Error {
    case missingDeletionTarget
    case missingPerformanceTarget
    case performanceLoadTimedOut
    case memoryMeasurementFailed
}

private struct StageFourSmokeResult {
    let schemaV2: Bool
    let seeded65: Bool
    let page50And15: Bool
    let panelSliceReady: Bool
    let enteredDetail: Bool
    let autoExpanded: Bool
    let debounceSaved: Bool
    let categoryMarkedUser: Bool
    let escapeReturned: Bool
    let deleteUndoExact: Bool
    let deleteExpired: Bool
    let reopenRestored: Bool
    let recentSynced: Bool
    let panelReset: Bool
    let namedPasteboard: Bool
    let generalPasteboardUntouched: Bool
    let productionDataUntouched: Bool
    let performance: StageFourPerformanceResult

    var allPassed: Bool {
        schemaV2
            && seeded65
            && page50And15
            && panelSliceReady
            && enteredDetail
            && autoExpanded
            && debounceSaved
            && categoryMarkedUser
            && escapeReturned
            && deleteUndoExact
            && deleteExpired
            && reopenRestored
            && recentSynced
            && panelReset
            && namedPasteboard
            && generalPasteboardUntouched
            && productionDataUntouched
            && performance.targetPassed
    }
}

private struct StageFourPerformanceResult {
    let itemCount: Int
    let loadedItemCount: Int
    let firstPageMedianMilliseconds: Double
    let firstPageP95Milliseconds: Double
    let allPagesMilliseconds: Double
    let pageP95Milliseconds: Double
    let textUpdateP95Milliseconds: Double
    let categoryUpdateP95Milliseconds: Double
    let residentMegabytes: Double
    let physicalFootprintMegabytes: Double

    var targetPassed: Bool {
        itemCount == 1_000
            && loadedItemCount == 1_000
            && firstPageMedianMilliseconds > 0
            && firstPageP95Milliseconds < 100
            && pageP95Milliseconds < 100
            && textUpdateP95Milliseconds < 100
            && categoryUpdateP95Milliseconds < 100
            && residentMegabytes > 0
            && physicalFootprintMegabytes > 0
            && physicalFootprintMegabytes < 150
    }
}
#endif
