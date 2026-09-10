#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import JotBloomCore
import UniformTypeIdentifiers

struct StageThreeSmokeBootstrap {
    let dataDirectoryURL: URL
    let expectedInspirationTitle: String
    let expectedInspirationBody: String
    let expectedDraftContent: String
    let productionDirectoryURL: URL
    let productionSnapshotBefore: DebugDirectorySnapshot
}

@MainActor
final class StageThreeSmokeRunner {
    private let bootstrap: StageThreeSmokeBootstrap
    private let store: JotBloomStore
    private let service: ClipboardService
    private let pasteboard: NSPasteboard
    private let monitor: PasteboardMonitor
    private let viewModel: ClipboardHistoryViewModel
    private let coordinator: PanelVisibilityCoordinator
    private let panelController: PanelController

    init(
        bootstrap: StageThreeSmokeBootstrap,
        store: JotBloomStore,
        service: ClipboardService,
        pasteboard: NSPasteboard,
        monitor: PasteboardMonitor,
        viewModel: ClipboardHistoryViewModel,
        coordinator: PanelVisibilityCoordinator,
        panelController: PanelController
    ) {
        self.bootstrap = bootstrap
        self.store = store
        self.service = service
        self.pasteboard = pasteboard
        self.monitor = monitor
        self.viewModel = viewModel
        self.coordinator = coordinator
        self.panelController = panelController
    }

    func run() {
        Task { [self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                let result = try await execute()
                let idleHoldSeconds = configuredIdleHoldSeconds
                if idleHoldSeconds > 0 {
                    try? await Task.sleep(
                        nanoseconds: idleHoldSeconds * 1_000_000_000
                    )
                }
                let elapsedMilliseconds = (
                    ProcessInfo.processInfo.systemUptime - startedAt
                ) * 1_000
                print(
                    "JOTBLOOM_STAGE3_SMOKE "
                        + "success=\(result.allPassed) "
                        + "schema_current=\(result.schemaV2) "
                        + "backup_v1=\(result.backupV1) "
                        + "legacy_data_preserved=\(result.legacyDataPreserved) "
                        + "startup_baseline=\(result.startupBaseline) "
                        + "lifecycle_pause_resume=\(result.lifecyclePauseResume) "
                        + "text_captured=\(result.textCaptured) "
                        + "link_captured=\(result.linkCaptured) "
                        + "image_captured=\(result.imageCaptured) "
                        + "dedupe_refreshed=\(result.dedupeRefreshed) "
                        + "concealed_skipped=\(result.concealedSkipped) "
                        + "file_skipped=\(result.fileSkipped) "
                        + "retention_applied=\(result.retentionApplied) "
                        + "self_write_suppressed=\(result.selfWriteSuppressed) "
                        + "reopen_restored=\(result.reopenRestored) "
                        + "panel_slice_ready=\(result.panelSliceReady) "
                        + "delete_undo=\(result.deleteUndo) "
                        + "panel_reset=\(result.panelReset) "
                        + "polling_modes=\(result.pollingModes) "
                        + "named_pasteboard=true "
                        + "production_data_untouched=\(result.productionDataUntouched) "
                        + "final_count=\(result.finalCount) "
                        + String(
                            format: "text_median_ms=%.3f ",
                            result.textMedianMilliseconds
                        )
                        + String(
                            format: "text_p95_ms=%.3f ",
                            result.textP95Milliseconds
                        )
                        + String(
                            format: "image_640_ms=%.3f ",
                            result.imageSmallMilliseconds
                        )
                        + String(
                            format: "image_1920_ms=%.3f ",
                            result.imageLargeMilliseconds
                        )
                        + "idle_hold_s=\(idleHoldSeconds) "
                        + String(format: "elapsed_ms=%.3f", elapsedMilliseconds)
                )
            } catch {
                print(
                    "JOTBLOOM_STAGE3_SMOKE "
                        + "success=false error=true named_pasteboard=true"
                )
            }
            NSApp.terminate(nil)
        }
    }

    private func execute() async throws -> StageThreeSmokeResult {
        let databaseURL = store.databaseURL
        let backupURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("\(databaseURL.lastPathComponent).bak-v1")
        let migrated = try StageThreeDebugHarness.inspectDatabase(
            databaseURL: databaseURL
        )
        let backup = try StageThreeDebugHarness.inspectDatabase(
            databaseURL: backupURL
        )
        let schemaV2 = migrated.schemaVersion == DatabaseMigrator.currentVersion
            && migrated.hasClipboardTable
        let backupV1 = backup.schemaVersion == 1
            && !backup.hasClipboardTable
        let legacyDataPreserved = migrated.inspirationTitle
                == bootstrap.expectedInspirationTitle
            && migrated.inspirationBody == bootstrap.expectedInspirationBody
            && migrated.draftContent == bootstrap.expectedDraftContent
            && backup.inspirationTitle == bootstrap.expectedInspirationTitle
            && backup.inspirationBody == bootstrap.expectedInspirationBody
            && backup.draftContent == bootstrap.expectedDraftContent

        _ = await waitUntil { self.viewModel.isReady }
        let startupBaseline = try store.listClipboardItemsSynchronously().isEmpty
        let backgroundMode = monitor.debugInterval
            == PasteboardMonitor.backgroundInterval

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        let paused = await waitUntil { self.monitor.debugIsPaused }
        let pausedValue = "stage-three-paused-\(UUID().uuidString)"
        try writeString(pausedValue)
        monitor.pollNow()
        try await Task.sleep(nanoseconds: 20_000_000)
        let skippedWhilePaused = try store
            .listClipboardItemsSynchronously().isEmpty
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let resumedAndCaptured = await waitUntil {
            (try? self.store.listClipboardItemsSynchronously())?
                .contains(where: { $0.textContent == pausedValue }) == true
        }
        if let resumedItem = try store.listClipboardItemsSynchronously()
            .first(where: { $0.textContent == pausedValue }) {
            _ = try await service.delete(id: resumedItem.id)
            await service.finalizeDeletion(resumedItem)
        }
        let lifecyclePauseResume = paused
            && skippedWhilePaused
            && resumedAndCaptured
            && !monitor.debugIsPaused

        let text = "stage-three-smoke-\(UUID().uuidString)"
        try writeString(text)
        monitor.pollNow()
        let textCaptured = await waitUntil {
            (try? self.store.listClipboardItemsSynchronously())?
                .contains(where: { $0.textContent == text }) == true
        }
        let firstTextItem = try store.listClipboardItemsSynchronously()
            .first(where: { $0.textContent == text })

        try await Task.sleep(nanoseconds: 3_000_000)
        try writeString(text)
        monitor.pollNow()
        let dedupeRefreshed = await waitUntil {
            guard let items = try? self.store.listClipboardItemsSynchronously(),
                  let refreshed = items.first(where: { $0.textContent == text }),
                  let firstTextItem else {
                return false
            }
            return items.count == 1
                && refreshed.id == firstTextItem.id
                && refreshed.copiedAtUTCms > firstTextItem.copiedAtUTCms
                && items.first?.id == refreshed.id
        }

        let link = "https://example.com/\(UUID().uuidString)"
        try writeString(link)
        monitor.pollNow()
        let linkCaptured = await waitUntil {
            (try? self.store.listClipboardItemsSynchronously())?
                .contains(where: {
                    $0.textContent == link && $0.contentType == .link
                }) == true
        }

        try writeImage(try makeImageData())
        monitor.pollNow()
        let imageCaptured = await waitUntil {
            guard let item = try? self.store.listClipboardItemsSynchronously()
                .first(where: { $0.contentType == .image }) else {
                return false
            }
            let originalAvailable = await self.service.isImageAvailable(
                for: item
            )
            let thumbnailAvailable = await self.service.thumbnailURL(
                for: item
            ) != nil
            return originalAvailable && thumbnailAvailable
        }
        let afterImage = try store.listClipboardItemsSynchronously()
        let retentionApplied = afterImage.count == 2
            && afterImage.contains(where: { $0.contentType == .image })

        let countBeforeSensitiveChecks = afterImage.count
        try writeConcealedString()
        monitor.pollNow()
        try await Task.sleep(nanoseconds: 30_000_000)
        let concealedSkipped = try store
            .listClipboardItemsSynchronously().count == countBeforeSensitiveChecks

        try writeFileURL()
        monitor.pollNow()
        try await Task.sleep(nanoseconds: 30_000_000)
        let fileSkipped = try store
            .listClipboardItemsSynchronously().count == countBeforeSensitiveChecks

        _ = await waitUntil {
            self.viewModel.items.count == countBeforeSensitiveChecks
        }
        if let textItem = viewModel.items.first(where: { $0.textContent == text }) {
            viewModel.select(textItem.id)
        }
        let beforeSelfWrite = try store.listClipboardItemsSynchronously()
            .first(where: { $0.id == viewModel.selectedID })
        viewModel.copySelected(collapseAfterCopy: false)
        let copyCompleted = await waitUntil {
            self.viewModel.copiedItemID == self.viewModel.selectedID
        }
        monitor.pollNow()
        try await Task.sleep(nanoseconds: 30_000_000)
        let afterSelfWrite = try store.listClipboardItemsSynchronously()
            .first(where: { $0.id == beforeSelfWrite?.id })
        let countAfterSelfWrite = try store
            .listClipboardItemsSynchronously().count
        let selfWriteSuppressed = copyCompleted
            && beforeSelfWrite?.copiedAtUTCms == afterSelfWrite?.copiedAtUTCms
            && countAfterSelfWrite == countBeforeSensitiveChecks

        let reopened = try JotBloomStore(
            dataDirectoryURL: bootstrap.dataDirectoryURL
        )
        let reopenedItems = try reopened.listClipboardItemsSynchronously()
        let reopenedAssets = try ClipboardAssetStore(
            dataDirectoryURL: bootstrap.dataDirectoryURL
        )
        let reopenedImageAvailable = reopenedItems
            .first(where: { $0.contentType == .image })
            .flatMap { item -> Bool? in
                guard let image = item.imageFileName,
                      let thumbnail = item.thumbnailFileName else {
                    return nil
                }
                return reopenedAssets.filesExist(
                    names: ClipboardAssetNames(
                        imageFileName: image,
                        thumbnailFileName: thumbnail
                    )
                )
            } == true
        let reopenRestored = try reopened.schemaVersionSynchronously() == DatabaseMigrator.currentVersion
            && reopenedItems.count == countBeforeSensitiveChecks
            && reopenedImageAvailable
        reopened.close()

        coordinator.show()
        panelController.debugSelectClipboard()
        try await Task.sleep(nanoseconds: 50_000_000)
        let panelSnapshot = panelController.debugSnapshot
        let panelSliceReady = panelSnapshot.isVisible
            && panelSnapshot.isKey
            && panelSnapshot.selectedTab == PanelTab.clipboard.rawValue
            && viewModel.selectedID != nil
        let visibleMode = monitor.debugInterval
            == PasteboardMonitor.visiblePanelInterval

        let countBeforeDelete = try store.listClipboardItemsSynchronously().count
        viewModel.deleteSelected()
        let deleted = await waitUntil {
            (try? self.store.listClipboardItemsSynchronously().count)
                == countBeforeDelete - 1
                && self.viewModel.canUndo
        }
        viewModel.undoDeletion()
        let restored = await waitUntil {
            (try? self.store.listClipboardItemsSynchronously().count)
                == countBeforeDelete
                && !self.viewModel.canUndo
        }
        let deleteUndo = deleted && restored

        coordinator.hide(restoreFocus: false)
        let hiddenSnapshot = panelController.debugSnapshot
        let panelReset = !hiddenSnapshot.isVisible
            && hiddenSnapshot.selectedTab == PanelTab.inspiration.rawValue
        let restoredBackgroundMode = monitor.debugInterval
            == PasteboardMonitor.backgroundInterval
        let pollingModes = backgroundMode
            && visibleMode
            && restoredBackgroundMode

        let performance = try await runPerformanceProbe()

        let productionAfter = DebugDirectorySnapshot.capture(
            url: bootstrap.productionDirectoryURL
        )
        let productionDataUntouched = productionAfter
            == bootstrap.productionSnapshotBefore
        let finalCount = try store.listClipboardItemsSynchronously().count

        return StageThreeSmokeResult(
            schemaV2: schemaV2,
            backupV1: backupV1,
            legacyDataPreserved: legacyDataPreserved,
            startupBaseline: startupBaseline,
            lifecyclePauseResume: lifecyclePauseResume,
            textCaptured: textCaptured,
            linkCaptured: linkCaptured,
            imageCaptured: imageCaptured,
            dedupeRefreshed: dedupeRefreshed,
            concealedSkipped: concealedSkipped,
            fileSkipped: fileSkipped,
            retentionApplied: retentionApplied,
            selfWriteSuppressed: selfWriteSuppressed,
            reopenRestored: reopenRestored,
            panelSliceReady: panelSliceReady,
            deleteUndo: deleteUndo,
            panelReset: panelReset,
            pollingModes: pollingModes,
            productionDataUntouched: productionDataUntouched,
            finalCount: finalCount,
            textMedianMilliseconds: performance.textMedianMilliseconds,
            textP95Milliseconds: performance.textP95Milliseconds,
            imageSmallMilliseconds: performance.imageSmallMilliseconds,
            imageLargeMilliseconds: performance.imageLargeMilliseconds
        )
    }

    private func writeString(_ string: String) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(string, forType: .string) else {
            throw ClipboardWriteError.writeFailed
        }
    }

    private func writeImage(_ data: Data) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            throw ClipboardWriteError.writeFailed
        }
    }

    private func writeConcealedString() throws {
        let item = NSPasteboardItem()
        guard item.setString(
            "1",
            forType: NSPasteboard.PasteboardType(
                ClipboardPasteboardTypes.concealed
            )
        ),
        item.setString("sensitive-test-value", forType: .string) else {
            throw ClipboardWriteError.writeFailed
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ClipboardWriteError.writeFailed
        }
    }

    private func writeFileURL() throws {
        let item = NSPasteboardItem()
        guard item.setString("file:///tmp/jotbloom-smoke", forType: .fileURL),
              item.setString("file fallback", forType: .string) else {
            throw ClipboardWriteError.writeFailed
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ClipboardWriteError.writeFailed
        }
    }

    private func makeImageData(
        width: Int = 16,
        height: Int = 8
    ) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        context.setFillColor(
            CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        )
        context.fill(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let image = context.makeImage() else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardImageNormalizationError.encodingFailed
        }
        return data as Data
    }

    private func runPerformanceProbe() async throws -> StageThreePerformanceResult {
        let directory = bootstrap.dataDirectoryURL.appendingPathComponent(
            "PerformanceProbe-\(UUID().uuidString)",
            isDirectory: true
        )
        let probeStore = try JotBloomStore(dataDirectoryURL: directory)
        defer {
            probeStore.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let probeAssets = try ClipboardAssetStore(
            dataDirectoryURL: directory
        )
        let probeService = ClipboardService(
            store: probeStore,
            assetStore: probeAssets,
            retentionPolicy: ClipboardRetentionPolicy(
                maximumCount: 200,
                maximumAgeMilliseconds: nil,
                maximumBytes: nil
            )
        )
        let source = ClipboardSourceApplication(
            name: nil,
            bundleIdentifier: nil
        )
        var textDurations: [Double] = []
        for index in 0..<30 {
            let startedAt = ProcessInfo.processInfo.systemUptime
            _ = try await probeService.capture(
                ClipboardSnapshot(
                    content: .text(
                        "stage-three-performance-\(index)-\(UUID().uuidString)"
                    ),
                    copiedAtUTCms: Int64(index),
                    sourceApplication: source
                )
            )
            _ = try await probeService.listItems()
            textDurations.append(
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
        }
        let sorted = textDurations.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = min(
            sorted.count - 1,
            Int(ceil(Double(sorted.count) * 0.95)) - 1
        )

        let normalizer = SystemClipboardImageNormalizer()
        let smallData = try makeImageData(width: 640, height: 360)
        let smallStartedAt = ProcessInfo.processInfo.systemUptime
        _ = try normalizer.normalize(smallData)
        let smallMilliseconds = (
            ProcessInfo.processInfo.systemUptime - smallStartedAt
        ) * 1_000

        let largeData = try makeImageData(width: 1_920, height: 1_080)
        let largeStartedAt = ProcessInfo.processInfo.systemUptime
        _ = try normalizer.normalize(largeData)
        let largeMilliseconds = (
            ProcessInfo.processInfo.systemUptime - largeStartedAt
        ) * 1_000

        return StageThreePerformanceResult(
            textMedianMilliseconds: median,
            textP95Milliseconds: sorted[p95Index],
            imageSmallMilliseconds: smallMilliseconds,
            imageLargeMilliseconds: largeMilliseconds
        )
    }

    private var configuredIdleHoldSeconds: UInt64 {
        guard let rawValue = ProcessInfo.processInfo.environment[
            "JOTBLOOM_STAGE3_SMOKE_IDLE_SECONDS"
        ],
        let seconds = UInt64(rawValue),
        seconds <= 600 else {
            return 0
        }
        return seconds
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - started
                > timeoutNanoseconds {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }
}

private struct StageThreeSmokeResult {
    let schemaV2: Bool
    let backupV1: Bool
    let legacyDataPreserved: Bool
    let startupBaseline: Bool
    let lifecyclePauseResume: Bool
    let textCaptured: Bool
    let linkCaptured: Bool
    let imageCaptured: Bool
    let dedupeRefreshed: Bool
    let concealedSkipped: Bool
    let fileSkipped: Bool
    let retentionApplied: Bool
    let selfWriteSuppressed: Bool
    let reopenRestored: Bool
    let panelSliceReady: Bool
    let deleteUndo: Bool
    let panelReset: Bool
    let pollingModes: Bool
    let productionDataUntouched: Bool
    let finalCount: Int
    let textMedianMilliseconds: Double
    let textP95Milliseconds: Double
    let imageSmallMilliseconds: Double
    let imageLargeMilliseconds: Double

    var allPassed: Bool {
        schemaV2
            && backupV1
            && legacyDataPreserved
            && startupBaseline
            && lifecyclePauseResume
            && textCaptured
            && linkCaptured
            && imageCaptured
            && dedupeRefreshed
            && concealedSkipped
            && fileSkipped
            && retentionApplied
            && selfWriteSuppressed
            && reopenRestored
            && panelSliceReady
            && deleteUndo
            && panelReset
            && pollingModes
            && productionDataUntouched
            && finalCount == 2
            && textMedianMilliseconds > 0
            && textP95Milliseconds >= textMedianMilliseconds
            && imageSmallMilliseconds > 0
            && imageLargeMilliseconds > 0
    }
}

private struct StageThreePerformanceResult {
    let textMedianMilliseconds: Double
    let textP95Milliseconds: Double
    let imageSmallMilliseconds: Double
    let imageLargeMilliseconds: Double
}

struct DebugDirectorySnapshot: Equatable {
    struct Entry: Equatable {
        let relativePath: String
        let fileSize: UInt64?
        let modificationDate: Date?
        let isDirectory: Bool
    }

    let exists: Bool
    let entries: [Entry]

    static func capture(
        url: URL,
        fileManager: FileManager = .default
    ) -> DebugDirectorySnapshot {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return DebugDirectorySnapshot(exists: false, entries: [])
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            return DebugDirectorySnapshot(exists: true, entries: [])
        }

        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        var entries: [Entry] = []
        for case let candidate as URL in enumerator {
            let values = try? candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey
            ])
            entries.append(
                Entry(
                    relativePath: String(candidate.path.dropFirst(root.count)),
                    fileSize: values?.fileSize.map(UInt64.init),
                    modificationDate: values?.contentModificationDate,
                    isDirectory: values?.isDirectory == true
                )
            )
        }
        return DebugDirectorySnapshot(
            exists: true,
            entries: entries.sorted { $0.relativePath < $1.relativePath }
        )
    }
}
#endif
