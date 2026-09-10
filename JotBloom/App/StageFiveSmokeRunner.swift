#if DEBUG
import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import JotBloomCore

struct StageFiveSmokeBootstrap {
    let dataDirectoryURL: URL
    let sharedTextID: Int64
    let sharedLinkID: Int64
    let sharedText: String
    let sharedLink: String
    let stableClipboardIDs: [Int64]
    let stableInspirationIDs: [Int64]
    let oldInspirationID: Int64
    let expectedBulkMatchCount: Int
    let scannedRowCount: Int
    let scannedCharacterCount: Int
    let productionDirectoryURL: URL
    let productionSnapshotBefore: DebugDirectorySnapshot
    let generalPasteboardChangeCountBefore: Int
}

@MainActor
final class StageFiveSmokeRunner {
    private let bootstrap: StageFiveSmokeBootstrap
    private let store: JotBloomStore
    private let namedPasteboard: NSPasteboard
    private let inputViewModel: InspirationInputViewModel
    private let libraryViewModel: InspirationLibraryViewModel
    private let searchViewModel: GlobalSearchViewModel
    private let pasteboardMonitor: PasteboardMonitor
    private let coordinator: PanelVisibilityCoordinator
    private let panelController: PanelController

    init(
        bootstrap: StageFiveSmokeBootstrap,
        store: JotBloomStore,
        namedPasteboard: NSPasteboard,
        inputViewModel: InspirationInputViewModel,
        libraryViewModel: InspirationLibraryViewModel,
        searchViewModel: GlobalSearchViewModel,
        pasteboardMonitor: PasteboardMonitor,
        coordinator: PanelVisibilityCoordinator,
        panelController: PanelController
    ) {
        self.bootstrap = bootstrap
        self.store = store
        self.namedPasteboard = namedPasteboard
        self.inputViewModel = inputViewModel
        self.libraryViewModel = libraryViewModel
        self.searchViewModel = searchViewModel
        self.pasteboardMonitor = pasteboardMonitor
        self.coordinator = coordinator
        self.panelController = panelController
    }

    func run() {
        Task { [self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            var smokePassed = false
            do {
                let result = try await execute()
                var interfacePassed = true
                if ProcessInfo.processInfo.environment["JOTBLOOM_UI_SMOKE"] == "1" {
                    interfacePassed = try await panelController.debugRunInterfaceProbe()
                    print("JOTBLOOM_UI_SMOKE success=\(interfacePassed)")
                }
                smokePassed = result.allPassed && interfacePassed
                print(
                    "JOTBLOOM_STAGE5_SMOKE "
                        + "success=\(result.allPassed) "
                        + "schema_current=\(result.schemaV2) "
                        + "clipboard_text_match=\(result.clipboardTextMatch) "
                        + "clipboard_link_match=\(result.clipboardLinkMatch) "
                        + "clipboard_image_excluded=\(result.clipboardImageExcluded) "
                        + "inspiration_title_match=\(result.inspirationTitleMatch) "
                        + "inspiration_body_match=\(result.inspirationBodyMatch) "
                        + "unicode_case_insensitive=\(result.unicodeCaseInsensitive) "
                        + "special_characters_literal=\(result.specialCharactersLiteral) "
                        + "group_order=\(result.groupOrder) "
                        + "stable_item_order=\(result.stableItemOrder) "
                        + "all_matches_returned=\(result.allMatchesReturned) "
                        + "highlight_segments=\(result.highlightSegments) "
                        + "debounce_150ms=\(result.debounce150ms) "
                        + "debounce_finished=\(result.debounceFinished) "
                        + "debounce_phase=\(result.debounceObservedPhase) "
                        + String(
                            format: "debounce_elapsed_ms=%.3f ",
                            result.debounceElapsedMilliseconds
                        )
                        + "stale_result_rejected=\(result.staleResultRejected) "
                        + "failure_retry=\(result.failureRetry) "
                        + "command_6_focus=\(result.command6Focus) "
                        + "command_f_focus=\(result.commandFFocus) "
                        + "clipboard_enter_collapsed=\(result.clipboardEnterCollapsed) "
                        + "clipboard_command_c_stayed_open=\(result.clipboardCommandCStayedOpen) "
                        + "pasteboard_baseline_advanced=\(result.pasteboardBaselineAdvanced) "
                        + "search_inspiration_detail=\(result.searchInspirationDetail) "
                        + "detail_returned_to_search=\(result.detailReturnedToSearch) "
                        + "panel_reset=\(result.panelReset) "
                        + "empty_prompt_fixture_valid=\(result.promptSourceDeferred) "
                        + "production_data_untouched=\(result.productionDataUntouched) "
                        + "general_pasteboard_untouched=\(result.generalPasteboardUntouched) "
                        + "named_pasteboard=\(result.namedPasteboard) "
                        + "search_p95_under_100ms=\(result.performance.targetPassed) "
                        + "physical_footprint_under_150mb=\(result.physicalFootprintUnder150MB) "
                        + "performance_queries=\(result.performance.queryCount) "
                        + "scanned_rows=\(bootstrap.scannedRowCount) "
                        + "scanned_characters=\(bootstrap.scannedCharacterCount) "
                        + String(
                            format: "search_p50_ms=%.3f ",
                            result.performance.p50Milliseconds
                        )
                        + String(
                            format: "search_p95_ms=%.3f ",
                            result.performance.p95Milliseconds
                        )
                        + String(
                            format: "search_max_ms=%.3f ",
                            result.performance.maximumMilliseconds
                        )
                        + String(
                            format: "resident_mb=%.3f ",
                            result.residentMegabytes
                        )
                        + String(
                            format: "physical_footprint_mb=%.3f ",
                            result.physicalFootprintMegabytes
                        )
                        + String(
                            format: "elapsed_ms=%.3f",
                            milliseconds(since: startedAt)
                        )
                )
            } catch {
                print(
                    "JOTBLOOM_STAGE5_SMOKE "
                        + "success=false error=true named_pasteboard=true"
                )
            }
            if !smokePassed { exit(1) }
            NSApp.terminate(nil)
        }
    }

    private func execute() async throws -> StageFiveSmokeResult {
        panelController.debugSetAutomaticDismissalEnabled(false)
        let schemaV2 = try store.schemaVersionSynchronously() == DatabaseMigrator.currentVersion
        let modelsReady = await waitUntil {
            self.inputViewModel.isReady
                && self.libraryViewModel.isReady
                && self.searchViewModel.phase == .idle
        }
        guard modelsReady else { throw StageFiveSmokeError.modelsNotReady }

        let shared = try store.searchAllSynchronously(query: "stage5-shared")
        let clipboardTextMatch = shared.clipboard.contains {
            $0.id.recordID == bootstrap.sharedTextID && $0.leadingKind == .text
        }
        let clipboardLinkMatch = shared.clipboard.contains {
            $0.id.recordID == bootstrap.sharedLinkID && $0.leadingKind == .link
        }
        let inspirationTitleMatch = shared.inspirations.contains {
            $0.displayText.localizedCaseInsensitiveContains("stage5-shared")
                && $0.id.recordID != bootstrap.oldInspirationID
        }
        let inspirationBodyMatch = shared.inspirations.contains {
            $0.id.recordID == bootstrap.oldInspirationID
        }
        let clipboardImageExcluded = try store
            .searchAllSynchronously(query: "Stage5ImageOnly")
            .isEmpty
        let unicode = try store.searchAllSynchronously(query: "café")
        let unicodeCaseInsensitive = !unicode.clipboard.isEmpty
            && !unicode.inspirations.isEmpty
            && SearchTextMatcher.contains("É", in: "e\u{301}")
        let special = try store.searchAllSynchronously(query: "%_'\\")
        let specialCharactersLiteral = !special.clipboard.isEmpty
            && !special.inspirations.isEmpty
        let sources = shared.allResults.map(\.source)
        let firstInspirationIndex = sources.firstIndex(of: .inspiration)
        let groupOrder = firstInspirationIndex.map { index in
            sources[..<index].allSatisfy { $0 == .clipboard }
                && sources[index...].allSatisfy { $0 == .inspiration }
        } ?? false
        let stableClipboard = try store
            .searchAllSynchronously(query: "stable-clipboard")
            .clipboard
            .map(\.id.recordID)
        let stableInspirations = try store
            .searchAllSynchronously(query: "stable-inspiration")
            .inspirations
            .map(\.id.recordID)
        let stableItemOrder = stableClipboard == bootstrap.stableClipboardIDs.sorted(by: >)
            && stableInspirations == bootstrap.stableInspirationIDs.sorted(by: >)
        let allMatches = try store.searchAllSynchronously(query: "bulk-common")
        let allMatchesReturned = allMatches.allResults.count
            == bootstrap.expectedBulkMatchCount
        let highlighted = try store.searchAllSynchronously(query: "stage5-highlight")
        let highlightSegments = highlighted.allResults.count == 2
            && highlighted.allResults.allSatisfy {
                $0.segments.filter(\.isHighlighted).count == 2
            }
        let promptSourceDeferred = shared.prompts.isEmpty
            && allMatches.prompts.isEmpty

        let performance = try runPerformanceProbe()
        let staleResultRejected = await runStaleResultProbe()
        let failureRetry = await runFailureRetryProbe()

        coordinator.show()
        let initialPanelReady = await waitUntil {
            let snapshot = self.panelController.debugSnapshot
            return snapshot.isVisible
                && snapshot.selectedTab == PanelTab.inspiration.rawValue
        }
        guard initialPanelReady else { throw StageFiveSmokeError.panelNotReady }

        let command6FocusBefore = searchViewModel.focusRequest
        let command6Handled = panelController.debugPerformKeyEquivalent(
            keyCode: UInt16(kVK_ANSI_6),
            modifiers: .command
        )
        let command6Focused = await waitUntil {
            let snapshot = self.panelController.debugSnapshot
            return snapshot.selectedTab == PanelTab.globalSearch.rawValue
                && snapshot.textInputFocused
                && self.searchViewModel.focusRequest > command6FocusBefore
        }
        let command6Focus = command6Handled && command6Focused

        panelController.debugSelectInspiration()
        _ = await waitUntil {
            self.panelController.debugSnapshot.selectedTab
                == PanelTab.inspiration.rawValue
        }
        let commandFFocusBefore = searchViewModel.focusRequest
        let commandFHandled = panelController.debugPerformKeyEquivalent(
            keyCode: UInt16(kVK_ANSI_F),
            modifiers: .command
        )
        let commandFFocused = await waitUntil {
            let snapshot = self.panelController.debugSnapshot
            return snapshot.selectedTab == PanelTab.globalSearch.rawValue
                && snapshot.textInputFocused
                && self.searchViewModel.focusRequest > commandFFocusBefore
        }
        let commandFFocus = commandFHandled && commandFFocused

        panelController.debugClearMarkedText()
        guard await waitUntil(condition: {
            self.panelController.debugSnapshot.textInputFocused
                && !self.panelController.debugSnapshot.hasMarkedText
        }) else {
            throw StageFiveSmokeError.panelNotReady
        }
        // Let the newly focused SwiftUI field editor finish propagating its
        // initial value before the harness simulates user input.
        try await Task.sleep(nanoseconds: 20_000_000)
        let debounceStartedAt = ProcessInfo.processInfo.systemUptime
        searchViewModel.query = "stage5-debounce-no-result"
        let enteredDebouncing = searchViewModel.phase == .debouncing
        let debounceFinished = await waitUntil {
            self.searchViewModel.phase == .empty
        }
        let debounceElapsed = milliseconds(since: debounceStartedAt)
        let debounceObservedPhase = String(describing: searchViewModel.phase)
        let debounce150ms = enteredDebouncing
            && debounceFinished
            && debounceElapsed >= 140

        searchViewModel.query = "stage5-shared"
        guard await waitUntil(condition: {
            self.searchViewModel.phase == .results
                && self.searchViewModel.snapshot.allResults.count == shared.allResults.count
        }) else {
            throw StageFiveSmokeError.searchNotReady
        }

        searchViewModel.select(
            SearchResultID(source: .clipboard, recordID: bootstrap.sharedTextID)
        )
        let commandCHandled = panelController.debugPerformKeyEquivalent(
            keyCode: UInt16(kVK_ANSI_C),
            modifiers: .command
        )
        let commandCCopied = await waitUntil {
            self.namedPasteboard.string(forType: .string) == self.bootstrap.sharedText
                && self.searchViewModel.feedback?.kind == .copied
        }
        let clipboardCommandCStayedOpen = commandCHandled
            && commandCCopied
            && panelController.debugSnapshot.isVisible
            && panelController.debugSnapshot.selectedTab
                == PanelTab.globalSearch.rawValue
        let pasteboardBaselineAdvanced = pasteboardMonitor.debugLastSeenChangeCount
            == namedPasteboard.changeCount

        panelController.debugClearMarkedText()
        if searchViewModel.query != "stage5-shared" {
            searchViewModel.query = "stage5-shared"
        }
        guard await waitUntil(condition: {
            self.searchViewModel.phase == .results
                && self.searchViewModel.snapshot.allResults.count
                    == shared.allResults.count
                && !self.panelController.debugSnapshot.hasMarkedText
        }) else {
            throw StageFiveSmokeError.searchNotReady
        }
        searchViewModel.select(
            SearchResultID(source: .clipboard, recordID: bootstrap.sharedLinkID)
        )
        let enterSelectionReady = searchViewModel.selectedID == SearchResultID(
            source: .clipboard,
            recordID: bootstrap.sharedLinkID
        )
        let enterPanelReady = panelController.debugSnapshot.isVisible
            && panelController.debugSnapshot.selectedTab
                == PanelTab.globalSearch.rawValue
        let enterMarkedTextClear = !panelController.debugSnapshot.hasMarkedText
        panelController.debugSendKeyDown(keyCode: UInt16(kVK_Return))
        let clipboardEnterCollapsed = await waitUntil {
            !self.panelController.debugSnapshot.isVisible
                && self.namedPasteboard.string(forType: .string) == self.bootstrap.sharedLink
        }
        if !clipboardEnterCollapsed {
            print(
                "JOTBLOOM_STAGE5_DIAGNOSTIC "
                    + "enter_selection_ready=\(enterSelectionReady) "
                    + "enter_panel_ready=\(enterPanelReady) "
                    + "enter_marked_text_clear=\(enterMarkedTextClear) "
                    + "enter_panel_hidden=\(!panelController.debugSnapshot.isVisible) "
                    + "enter_pasteboard_written=\(namedPasteboard.string(forType: .string) == bootstrap.sharedLink) "
                    + "enter_search_phase=\(searchViewModel.phase) "
                    + "enter_selected_source=\(String(describing: searchViewModel.selectedID?.source))"
            )
        }

        coordinator.show()
        _ = panelController.debugPerformKeyEquivalent(
            keyCode: UInt16(kVK_ANSI_6),
            modifiers: .command
        )
        searchViewModel.query = "stage5-old-detail"
        guard await waitUntil(condition: {
            self.searchViewModel.phase == .results
                && self.searchViewModel.snapshot.inspirations.count == 1
        }) else {
            throw StageFiveSmokeError.searchNotReady
        }
        searchViewModel.select(
            SearchResultID(
                source: .inspiration,
                recordID: bootstrap.oldInspirationID
            )
        )
        panelController.debugSendKeyDown(keyCode: UInt16(kVK_Return))
        let searchInspirationDetail = await waitUntil {
            let snapshot = self.panelController.debugSnapshot
            return self.libraryViewModel.screen == .detail
                && self.libraryViewModel.detailInspiration?.id
                    == self.bootstrap.oldInspirationID
                && !self.libraryViewModel.isDetailLoading
                && snapshot.selectedTab == PanelTab.globalSearch.rawValue
                && snapshot.detailOrigin.contains("globalSearch")
        }

        libraryViewModel.detailBody = "edited from global search without old token"
        let detailSaved = await waitUntil {
            guard let loaded = try? self.store.inspirationSynchronously(
                id: self.bootstrap.oldInspirationID
            ) else {
                return false
            }
            return loaded.body == "edited from global search without old token"
                && !self.libraryViewModel.hasPendingSave
        }
        let escapeHandled = panelController.debugPerformKeyEquivalent(
            keyCode: UInt16(kVK_Escape)
        )
        let didReturnToSearch = await waitUntil {
            let snapshot = self.panelController.debugSnapshot
            return self.libraryViewModel.screen == .list
                && snapshot.selectedTab == PanelTab.globalSearch.rawValue
                && snapshot.detailOrigin == "nil"
                && self.searchViewModel.phase == .empty
        }
        let detailReturnedToSearch = escapeHandled
            && detailSaved
            && didReturnToSearch

        coordinator.hide(restoreFocus: false)
        let hiddenSnapshot = panelController.debugSnapshot
        coordinator.show()
        let shownSnapshot = panelController.debugSnapshot
        let panelReset = !hiddenSnapshot.isVisible
            && hiddenSnapshot.selectedTab == PanelTab.inspiration.rawValue
            && hiddenSnapshot.searchPhase
                == String(describing: GlobalSearchPhase.idle)
            && hiddenSnapshot.searchResultCount == 0
            && hiddenSnapshot.detailOrigin == "nil"
            && !hiddenSnapshot.isExpanded
            && shownSnapshot.isVisible
            && shownSnapshot.selectedTab == PanelTab.inspiration.rawValue
            && !shownSnapshot.isExpanded
        coordinator.hide(restoreFocus: false)

        let resident = try measuredResidentMemoryBytes()
        let footprint = try measuredPhysicalFootprintBytes()
        let residentMegabytes = Double(resident) / 1_048_576
        let physicalFootprintMegabytes = Double(footprint) / 1_048_576
        let physicalFootprintUnder150MB = physicalFootprintMegabytes > 0
            && physicalFootprintMegabytes < 150
        let namedPasteboard = namedPasteboard.name != .general
        let generalPasteboardUntouched = NSPasteboard.general.changeCount
            == bootstrap.generalPasteboardChangeCountBefore
        let productionDataUntouched = DebugDirectorySnapshot.capture(
            url: bootstrap.productionDirectoryURL
        ) == bootstrap.productionSnapshotBefore

        return StageFiveSmokeResult(
            schemaV2: schemaV2,
            clipboardTextMatch: clipboardTextMatch,
            clipboardLinkMatch: clipboardLinkMatch,
            clipboardImageExcluded: clipboardImageExcluded,
            inspirationTitleMatch: inspirationTitleMatch,
            inspirationBodyMatch: inspirationBodyMatch,
            unicodeCaseInsensitive: unicodeCaseInsensitive,
            specialCharactersLiteral: specialCharactersLiteral,
            groupOrder: groupOrder,
            stableItemOrder: stableItemOrder,
            allMatchesReturned: allMatchesReturned,
            highlightSegments: highlightSegments,
            debounce150ms: debounce150ms,
            debounceFinished: debounceFinished,
            debounceObservedPhase: debounceObservedPhase,
            debounceElapsedMilliseconds: debounceElapsed,
            staleResultRejected: staleResultRejected,
            failureRetry: failureRetry,
            command6Focus: command6Focus,
            commandFFocus: commandFFocus,
            clipboardEnterCollapsed: clipboardEnterCollapsed,
            clipboardCommandCStayedOpen: clipboardCommandCStayedOpen,
            pasteboardBaselineAdvanced: pasteboardBaselineAdvanced,
            searchInspirationDetail: searchInspirationDetail,
            detailReturnedToSearch: detailReturnedToSearch,
            panelReset: panelReset,
            promptSourceDeferred: promptSourceDeferred,
            productionDataUntouched: productionDataUntouched,
            generalPasteboardUntouched: generalPasteboardUntouched,
            namedPasteboard: namedPasteboard,
            residentMegabytes: residentMegabytes,
            physicalFootprintMegabytes: physicalFootprintMegabytes,
            physicalFootprintUnder150MB: physicalFootprintUnder150MB,
            performance: performance
        )
    }

    private func runPerformanceProbe() throws -> StageFiveSearchPerformance {
        let queries = [
            "stage5-shared",
            "bulk-common",
            "tail-marker-999",
            "stage5-performance-no-result"
        ]
        var durations: [Double] = []
        for index in 0..<100 {
            let query = queries[index % queries.count]
            if index.isMultiple(of: 20) {
                let reopened = try JotBloomStore(
                    dataDirectoryURL: bootstrap.dataDirectoryURL
                )
                let startedAt = ProcessInfo.processInfo.systemUptime
                _ = try reopened.searchAllSynchronously(query: query)
                durations.append(milliseconds(since: startedAt))
                reopened.close()
            } else {
                let startedAt = ProcessInfo.processInfo.systemUptime
                _ = try store.searchAllSynchronously(query: query)
                durations.append(milliseconds(since: startedAt))
            }
        }
        return StageFiveSearchPerformance(
            queryCount: durations.count,
            p50Milliseconds: percentile(durations, fraction: 0.50),
            p95Milliseconds: percentile(durations, fraction: 0.95),
            maximumMilliseconds: durations.max() ?? 0
        )
    }

    private func runStaleResultProbe() async -> Bool {
        let old = GlobalSearchResult(
            id: SearchResultID(source: .clipboard, recordID: 1),
            source: .clipboard,
            leadingKind: .text,
            segments: [SearchTextSegment(text: "old", isHighlighted: true)],
            timestampUTCms: 1,
            accessibilityContext: "old"
        )
        let new = GlobalSearchResult(
            id: SearchResultID(source: .inspiration, recordID: 2),
            source: .inspiration,
            leadingKind: .inspiration,
            segments: [SearchTextSegment(text: "new", isHighlighted: true)],
            timestampUTCms: 2,
            accessibilityContext: "new"
        )
        let delayedStore = StageFiveDelayedSearchStore(
            snapshots: [
                "old": GlobalSearchSnapshot(
                    clipboard: [old],
                    prompts: [],
                    inspirations: []
                ),
                "new": GlobalSearchSnapshot(
                    clipboard: [],
                    prompts: [],
                    inspirations: [new]
                )
            ]
        )
        let probe = GlobalSearchViewModel(
            store: delayedStore,
            pasteboardWriter: SystemPasteboardClient(pasteboard: namedPasteboard),
            debounceNanoseconds: 0
        )
        probe.query = "old"
        guard await waitUntil(condition: { delayedStore.requests == ["old"] }) else {
            return false
        }
        probe.query = "new"
        guard await waitUntil(condition: {
            probe.snapshot.inspirations.first?.id.recordID == 2
        }) else {
            return false
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        return probe.snapshot.inspirations.map(\.id.recordID) == [2]
            && probe.snapshot.clipboard.isEmpty
    }

    private func runFailureRetryProbe() async -> Bool {
        let directory = bootstrap.dataDirectoryURL.appendingPathComponent(
            "StageFiveFailureRetry-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            let closedStore = try JotBloomStore(dataDirectoryURL: directory)
            _ = try closedStore.saveManualInspirationSynchronously(
                ParsedInspiration(title: "retry-target", body: "body"),
                timestampUTCms: 1
            )
            closedStore.close()
            let switchable = StageFiveSwitchableSearchStore(store: closedStore)
            let probe = GlobalSearchViewModel(
                store: switchable,
                pasteboardWriter: SystemPasteboardClient(pasteboard: namedPasteboard),
                debounceNanoseconds: 0
            )
            probe.query = "retry-target"
            guard await waitUntil(condition: { probe.phase == .failure }) else {
                return false
            }
            let reopened = try JotBloomStore(dataDirectoryURL: directory)
            switchable.replaceStore(reopened)
            probe.retry()
            let succeeded = await waitUntil {
                probe.phase == .results
                    && probe.snapshot.inspirations.count == 1
            }
            reopened.close()
            return succeeded
        } catch {
            return false
        }
    }

    private func measuredResidentMemoryBytes() throws -> UInt64 {
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
        guard result == KERN_SUCCESS else {
            throw StageFiveSmokeError.memoryMeasurementFailed
        }
        return UInt64(information.resident_size)
    }

    private func measuredPhysicalFootprintBytes() throws -> UInt64 {
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
        guard result == KERN_SUCCESS else {
            throw StageFiveSmokeError.memoryMeasurementFailed
        }
        return UInt64(information.phys_footprint)
    }

    private func percentile(
        _ values: [Double],
        fraction: Double
    ) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)
        )
        return sorted[index]
    }

    private func milliseconds(since startedAt: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
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

@MainActor
private final class StageFiveDelayedSearchStore: GlobalSearchStoring {
    let snapshots: [String: GlobalSearchSnapshot]
    private(set) var requests: [String] = []

    init(snapshots: [String: GlobalSearchSnapshot]) {
        self.snapshots = snapshots
    }

    func searchAll(query: String) async throws -> GlobalSearchSnapshot {
        requests.append(query)
        if query == "old" {
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                // A SQLite scan already in progress may not stop when its Task is cancelled.
            }
        } else {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return snapshots[query] ?? .empty
    }

    func searchableClipboardText(id: Int64) async throws -> String? {
        nil
    }
}

@MainActor
private final class StageFiveSwitchableSearchStore: GlobalSearchStoring {
    private var store: JotBloomStore

    init(store: JotBloomStore) {
        self.store = store
    }

    func replaceStore(_ store: JotBloomStore) {
        self.store = store
    }

    func searchAll(query: String) async throws -> GlobalSearchSnapshot {
        try await store.searchAll(query: query)
    }

    func searchableClipboardText(id: Int64) async throws -> String? {
        try await store.searchableClipboardText(id: id)
    }
}

private enum StageFiveSmokeError: Error {
    case modelsNotReady
    case panelNotReady
    case searchNotReady
    case memoryMeasurementFailed
}

private struct StageFiveSearchPerformance {
    let queryCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double

    var targetPassed: Bool {
        queryCount == 100
            && p50Milliseconds > 0
            && p95Milliseconds < 100
            && maximumMilliseconds > 0
    }
}

private struct StageFiveSmokeResult {
    let schemaV2: Bool
    let clipboardTextMatch: Bool
    let clipboardLinkMatch: Bool
    let clipboardImageExcluded: Bool
    let inspirationTitleMatch: Bool
    let inspirationBodyMatch: Bool
    let unicodeCaseInsensitive: Bool
    let specialCharactersLiteral: Bool
    let groupOrder: Bool
    let stableItemOrder: Bool
    let allMatchesReturned: Bool
    let highlightSegments: Bool
    let debounce150ms: Bool
    let debounceFinished: Bool
    let debounceObservedPhase: String
    let debounceElapsedMilliseconds: Double
    let staleResultRejected: Bool
    let failureRetry: Bool
    let command6Focus: Bool
    let commandFFocus: Bool
    let clipboardEnterCollapsed: Bool
    let clipboardCommandCStayedOpen: Bool
    let pasteboardBaselineAdvanced: Bool
    let searchInspirationDetail: Bool
    let detailReturnedToSearch: Bool
    let panelReset: Bool
    let promptSourceDeferred: Bool
    let productionDataUntouched: Bool
    let generalPasteboardUntouched: Bool
    let namedPasteboard: Bool
    let residentMegabytes: Double
    let physicalFootprintMegabytes: Double
    let physicalFootprintUnder150MB: Bool
    let performance: StageFiveSearchPerformance

    var allPassed: Bool {
        schemaV2
            && clipboardTextMatch
            && clipboardLinkMatch
            && clipboardImageExcluded
            && inspirationTitleMatch
            && inspirationBodyMatch
            && unicodeCaseInsensitive
            && specialCharactersLiteral
            && groupOrder
            && stableItemOrder
            && allMatchesReturned
            && highlightSegments
            && debounce150ms
            && staleResultRejected
            && failureRetry
            && command6Focus
            && commandFFocus
            && clipboardEnterCollapsed
            && clipboardCommandCStayedOpen
            && pasteboardBaselineAdvanced
            && searchInspirationDetail
            && detailReturnedToSearch
            && panelReset
            && promptSourceDeferred
            && productionDataUntouched
            && generalPasteboardUntouched
            && namedPasteboard
            && physicalFootprintUnder150MB
            && performance.targetPassed
    }
}
#endif
