import Foundation
import OSLog

public protocol ClipboardHistoryServicing: AnyObject {
    func prepare(nowUTCms: Int64) async throws -> [ClipboardItem]
    func capture(_ snapshot: ClipboardSnapshot) async throws -> ClipboardCaptureOutcome
    func listItems() async throws -> [ClipboardItem]
    func imageData(for item: ClipboardItem) async throws -> Data
    func thumbnailURL(for item: ClipboardItem) async -> URL?
    func isImageAvailable(for item: ClipboardItem) async -> Bool
    func delete(id: Int64) async throws -> ClipboardItem?
    func restore(_ item: ClipboardItem) async throws -> ClipboardItem
    func finalizeDeletion(_ item: ClipboardItem) async
}

public actor ClipboardService: ClipboardHistoryServicing {
    private let store: JotBloomStore
    private let assetStore: ClipboardAssetStore
    private let imageNormalizer: ClipboardImageNormalizing
    private var retentionPolicy: ClipboardRetentionPolicy
    private let capturePermission: CapturePermission?
    private let logger = Logger(
        subsystem: "com.jotbloom.mengsheng",
        category: "clipboard-storage"
    )

    public init(
        store: JotBloomStore,
        assetStore: ClipboardAssetStore,
        imageNormalizer: ClipboardImageNormalizing = SystemClipboardImageNormalizer(),
        retentionPolicy: ClipboardRetentionPolicy = .stageThreeDefault,
        capturePermission: CapturePermission? = nil
    ) {
        self.store = store
        self.assetStore = assetStore
        self.imageNormalizer = imageNormalizer
        self.retentionPolicy = retentionPolicy
        self.capturePermission = capturePermission
    }

    public func prepare(nowUTCms: Int64) async throws -> [ClipboardItem] {
        let referenced = try store
            .referencedClipboardAssetFileNamesSynchronously()
        let orphanCount = try assetStore.reconcile(
            referencedFileNames: referenced
        )
        if orphanCount > 0 {
            logger.info("Removed \(orphanCount, privacy: .public) orphan clipboard assets")
        }
        repairMissingThumbnails(
            in: try store.listClipboardItemsSynchronously()
        )
        try cleanUp(nowUTCms: nowUTCms)
        return try store.listClipboardItemsSynchronously()
    }

    public func capture(
        _ snapshot: ClipboardSnapshot
    ) async throws -> ClipboardCaptureOutcome {
        let token = capturePermission?.token
        guard capturePermission == nil || token != nil else { return .skipped }
        let outcome: ClipboardCaptureOutcome
        switch snapshot.content {
        case let .text(text):
            guard let contentType = ClipboardContentClassifier.classify(text) else {
                return .skipped
            }
            outcome = try commitCapture(token: token) { try store.upsertClipboardTextSynchronously(
                text: text,
                contentType: contentType,
                copiedAtUTCms: snapshot.copiedAtUTCms,
                sourceApplication: snapshot.sourceApplication
            ) }

        case let .image(data):
            let normalized = try imageNormalizer.normalize(data)
            outcome = try commitCapture(token: token) { try captureImage(
                normalized,
                copiedAtUTCms: snapshot.copiedAtUTCms,
                sourceApplication: snapshot.sourceApplication
            ) }
        }

        do {
            try cleanUp(nowUTCms: snapshot.copiedAtUTCms)
        } catch {
            logger.error("Clipboard retention cleanup failed")
        }
        return outcome
    }

    private func commitCapture(token: UInt64?, _ action: () throws -> ClipboardCaptureOutcome) rethrows -> ClipboardCaptureOutcome {
        guard let capturePermission else { return try action() }
        guard let token else { return .skipped }
        return try capturePermission.commit(token: token, action) ?? .skipped
    }

    public func listItems() async throws -> [ClipboardItem] {
        try store.listClipboardItemsSynchronously()
    }

    public func imageData(for item: ClipboardItem) async throws -> Data {
        guard item.contentType == .image,
              let fileName = item.imageFileName else {
            throw PersistenceError.invalidStoredValue(
                column: "clipboard_items.image_file_name"
            )
        }
        return try assetStore.readData(fileName: fileName)
    }

    public func thumbnailURL(for item: ClipboardItem) async -> URL? {
        guard item.contentType == .image,
              let fileName = item.thumbnailFileName else {
            return nil
        }
        return assetStore.readableURL(fileName: fileName)
    }

    public func isImageAvailable(for item: ClipboardItem) async -> Bool {
        guard item.contentType == .image,
              let fileName = item.imageFileName else {
            return false
        }
        return assetStore.readableURL(fileName: fileName) != nil
    }

    public func delete(id: Int64) async throws -> ClipboardItem? {
        try store.deleteClipboardItemSynchronously(id: id)
    }

    public func restore(_ item: ClipboardItem) async throws -> ClipboardItem {
        let restored = try store.restoreClipboardItemSynchronously(item)
        if restored.id != item.id {
            deleteAssetsIfUnreferenced(for: item)
        }
        return restored
    }

    public func finalizeDeletion(_ item: ClipboardItem) async {
        deleteAssetsIfUnreferenced(for: item)
    }

    private func captureImage(
        _ image: NormalizedClipboardImage,
        copiedAtUTCms: Int64,
        sourceApplication: ClipboardSourceApplication
    ) throws -> ClipboardCaptureOutcome {
        if let existing = try store.matchingClipboardImageSynchronously(
            byteCount: image.byteCount,
            sha256: image.sha256
        ) {
            if let names = assetNames(for: existing),
               !assetStore.filesExist(names: names) {
                try assetStore.writeImage(
                    pngData: image.pngData,
                    thumbnailPNGData: image.thumbnailPNGData,
                    names: names
                )
            }
            let refreshed = try store.refreshClipboardItemSynchronously(
                id: existing.id,
                contentType: .image,
                copiedAtUTCms: copiedAtUTCms,
                sourceApplication: sourceApplication
            )
            return .refreshed(refreshed)
        }

        let names = try assetStore.writeNewImage(
            pngData: image.pngData,
            thumbnailPNGData: image.thumbnailPNGData
        )
        do {
            let inserted = try store.insertClipboardImageSynchronously(
                names: names,
                byteCount: image.byteCount,
                sha256: image.sha256,
                widthPixels: image.widthPixels,
                heightPixels: image.heightPixels,
                copiedAtUTCms: copiedAtUTCms,
                sourceApplication: sourceApplication
            )
            return .inserted(inserted)
        } catch {
            try? assetStore.delete(names: names)
            throw error
        }
    }

    private func cleanUp(nowUTCms: Int64) throws {
        let items = try store.listClipboardItemsSynchronously()
        let identifiers = ClipboardCleanupPlanner.identifiersToDelete(
            from: items,
            policy: retentionPolicy,
            nowUTCms: nowUTCms
        )
        guard !identifiers.isEmpty else { return }

        let deleted = try store.deleteClipboardItemsSynchronously(
            ids: identifiers
        )
        for item in deleted {
            deleteAssetsIfUnreferenced(for: item)
        }
        logger.info("Removed \(deleted.count, privacy: .public) expired clipboard items")
    }

    public func applyRetention(_ policy: ClipboardRetentionPolicy, nowUTCms: Int64) throws {
        retentionPolicy = policy
        try cleanUp(nowUTCms: nowUTCms)
    }

    /// Caller holds the capture barrier and has invalidated pending per-row undo operations.
    public func clearHistory(snapshot: [ClipboardItem]? = nil) throws -> Bool {
        let items = try store.listClipboardItemsSynchronously()
        let targets: [ClipboardItem]
        if let snapshot {
            let expected = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // A recapture refreshes the same ID. Compare the record, not just its ID.
            targets = items.filter { expected[$0.id] == $0 }
        } else { targets = items }
        _ = try store.deleteClipboardItemsSynchronously(ids: targets.map(\.id), matching: snapshot)
        let remaining = try store.referencedClipboardAssetFileNamesSynchronously()
        do { _ = try assetStore.reconcile(referencedFileNames: remaining); return true }
        catch { return false }
    }

    public func retryOrphanCleanup() throws { _ = try assetStore.reconcile(referencedFileNames: store.referencedClipboardAssetFileNamesSynchronously()) }

    public func usage() throws -> ClipboardUsage {
        let items = try store.listClipboardItemsSynchronously()
        var content: Int64 = 0
        for item in items {
            let sum = content.addingReportingOverflow(item.contentByteCount)
            content = sum.overflow ? Int64.max : sum.partialValue
        }
        var disk: Int64 = 0
        let fm = FileManager.default
        let files = [store.databaseURL, URL(fileURLWithPath: store.databaseURL.path + "-wal"), URL(fileURLWithPath: store.databaseURL.path + "-shm")]
            + (try fm.contentsOfDirectory(at: assetStore.directoryURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]))
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            disk += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return ClipboardUsage(count: items.count, contentBytes: content, diskBytes: disk)
    }

    private func repairMissingThumbnails(in items: [ClipboardItem]) {
        for item in items where item.contentType == .image {
            guard let imageFileName = item.imageFileName,
                  let thumbnailFileName = item.thumbnailFileName,
                  assetStore.readableURL(fileName: imageFileName) != nil,
                  assetStore.readableURL(fileName: thumbnailFileName) == nil else {
                continue
            }
            do {
                let originalData = try assetStore.readData(
                    fileName: imageFileName
                )
                let normalized = try imageNormalizer.normalize(originalData)
                try assetStore.writeThumbnailPNGData(
                    normalized.thumbnailPNGData,
                    fileName: thumbnailFileName
                )
            } catch {
                logger.error("Clipboard thumbnail repair failed")
            }
        }
    }

    private func deleteAssetsIfUnreferenced(for item: ClipboardItem) {
        guard let names = assetNames(for: item) else { return }
        do {
            let references = try store
                .referencedClipboardAssetFileNamesSynchronously()
            guard !references.contains(names.imageFileName),
                  !references.contains(names.thumbnailFileName) else {
                return
            }
            try assetStore.delete(names: names)
        } catch {
            logger.error("Clipboard asset cleanup failed")
        }
    }

    private func assetNames(for item: ClipboardItem) -> ClipboardAssetNames? {
        guard item.contentType == .image,
              let imageFileName = item.imageFileName,
              let thumbnailFileName = item.thumbnailFileName else {
            return nil
        }
        return ClipboardAssetNames(
            imageFileName: imageFileName,
            thumbnailFileName: thumbnailFileName
        )
    }
}
