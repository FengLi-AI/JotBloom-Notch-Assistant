import Foundation
import XCTest
@testable import JotBloomCore

final class ClipboardServiceTests: XCTestCase {
    func testPrepareRemovesOrphanAssets() async throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let assets = try ClipboardAssetStore(dataDirectoryURL: directory)
        let orphan = try assets.writeNewImage(
            pngData: Data([1]),
            thumbnailPNGData: Data([2])
        )
        let service = ClipboardService(store: store, assetStore: assets)

        let prepared = try await service.prepare(nowUTCms: 100)
        XCTAssertEqual(prepared, [])
        XCTAssertFalse(assets.filesExist(names: orphan))
    }

    func testTextCaptureClassifiesDeduplicatesAndRefreshesSource() async throws {
        let context = try makeContext()
        defer { context.remove() }
        let service = context.service
        let firstSource = ClipboardSourceApplication(
            name: "Browser",
            bundleIdentifier: "com.example.browser"
        )
        let secondSource = ClipboardSourceApplication(
            name: "Editor",
            bundleIdentifier: "com.example.editor"
        )

        let first = try await service.capture(
            ClipboardSnapshot(
                content: .text(" https://example.com "),
                copiedAtUTCms: 1,
                sourceApplication: firstSource
            )
        )
        guard case let .inserted(inserted) = first else {
            return XCTFail("Expected insert")
        }
        XCTAssertEqual(inserted.contentType, .link)
        XCTAssertEqual(inserted.textContent, " https://example.com ")

        let second = try await service.capture(
            ClipboardSnapshot(
                content: .text(" https://example.com "),
                copiedAtUTCms: 2,
                sourceApplication: secondSource
            )
        )
        guard case let .refreshed(refreshed) = second else {
            return XCTFail("Expected refresh")
        }
        XCTAssertEqual(refreshed.id, inserted.id)
        XCTAssertEqual(refreshed.copiedAtUTCms, 2)
        XCTAssertEqual(refreshed.sourceApplication, secondSource)
        let items = try await service.listItems()
        XCTAssertEqual(items.count, 1)
    }

    func testEmptyAndOversizedTextAreSkippedWithoutRows() async throws {
        let context = try makeContext()
        defer { context.remove() }
        let source = ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        for text in ["", String(repeating: "x", count: 1_000_001)] {
            let outcome = try await context.service.capture(
                ClipboardSnapshot(
                    content: .text(text),
                    copiedAtUTCms: 1,
                    sourceApplication: source
                )
            )
            XCTAssertEqual(
                outcome,
                .skipped
            )
        }
        let items = try await context.service.listItems()
        XCTAssertEqual(items, [])
    }

    func testImageCaptureWritesAssetsDeduplicatesAndRepairsMissingFiles() async throws {
        let normalized = NormalizedClipboardImage(
            pngData: Data([137, 80, 78, 71]),
            thumbnailPNGData: Data([1, 2]),
            widthPixels: 80,
            heightPixels: 40,
            sha256: String(repeating: "b", count: 64)
        )
        let context = try makeContext(normalizedImage: normalized)
        defer { context.remove() }
        let source = ClipboardSourceApplication(
            name: "Images",
            bundleIdentifier: "com.example.images"
        )

        let first = try await context.service.capture(
            ClipboardSnapshot(
                content: .image(Data([9])),
                copiedAtUTCms: 10,
                sourceApplication: source
            )
        )
        guard case let .inserted(inserted) = first,
              let imageName = inserted.imageFileName,
              let thumbnailName = inserted.thumbnailFileName else {
            return XCTFail("Expected image insert")
        }
        let names = ClipboardAssetNames(
            imageFileName: imageName,
            thumbnailFileName: thumbnailName
        )
        XCTAssertTrue(context.assets.filesExist(names: names))
        let storedImageData = try await context.service.imageData(for: inserted)
        XCTAssertEqual(storedImageData, normalized.pngData)

        try context.assets.delete(names: names)
        XCTAssertFalse(context.assets.filesExist(names: names))
        let second = try await context.service.capture(
            ClipboardSnapshot(
                content: .image(Data([10])),
                copiedAtUTCms: 11,
                sourceApplication: source
            )
        )
        guard case let .refreshed(refreshed) = second else {
            return XCTFail("Expected image refresh")
        }
        XCTAssertEqual(refreshed.id, inserted.id)
        XCTAssertTrue(context.assets.filesExist(names: names))
        let items = try await context.service.listItems()
        XCTAssertEqual(items.count, 1)
    }

    func testRetentionCountDeletesOldestAfterCapture() async throws {
        let context = try makeContext(
            policy: ClipboardRetentionPolicy(
                maximumCount: 2,
                maximumAgeMilliseconds: nil,
                maximumBytes: nil
            )
        )
        defer { context.remove() }
        let source = ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        for index in 1...3 {
            _ = try await context.service.capture(
                ClipboardSnapshot(
                    content: .text("item-\(index)"),
                    copiedAtUTCms: Int64(index),
                    sourceApplication: source
                )
            )
        }

        let storedText = try await context.service.listItems()
            .compactMap(\.textContent)
        XCTAssertEqual(storedText, ["item-3", "item-2"])
    }

    func testDatabaseInsertFailureCompensatesNewImageFiles() async throws {
        let normalized = NormalizedClipboardImage(
            pngData: Data([1, 2, 3]),
            thumbnailPNGData: Data([4]),
            widthPixels: 3,
            heightPixels: 1,
            sha256: String(repeating: "c", count: 64)
        )
        let context = try makeContext(normalizedImage: normalized)
        defer { context.remove() }
        try context.store.performSync { connection in
            try connection.execute(
                """
                CREATE TRIGGER fail_image_insert
                BEFORE INSERT ON clipboard_items
                WHEN NEW.content_type = 'image'
                BEGIN
                    SELECT RAISE(ABORT, 'test');
                END
                """,
                operation: "test_fail_image_insert"
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await context.service.capture(
                ClipboardSnapshot(
                    content: .image(Data([9])),
                    copiedAtUTCms: 1,
                    sourceApplication: ClipboardSourceApplication(
                        name: nil,
                        bundleIdentifier: nil
                    )
                )
            )
        )
        let urls = try FileManager.default.contentsOfDirectory(
            at: context.assets.directoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(urls.isEmpty)
        let items = try await context.service.listItems()
        XCTAssertEqual(items, [])
    }

    func testManualDeleteKeepsImageUntilUndoExpiresAndRestoreKeepsAssets() async throws {
        let normalized = NormalizedClipboardImage(
            pngData: Data([1]),
            thumbnailPNGData: Data([2]),
            widthPixels: 1,
            heightPixels: 1,
            sha256: String(repeating: "d", count: 64)
        )
        let context = try makeContext(normalizedImage: normalized)
        defer { context.remove() }
        let outcome = try await context.service.capture(
            ClipboardSnapshot(
                content: .image(Data([8])),
                copiedAtUTCms: 1,
                sourceApplication: ClipboardSourceApplication(
                    name: nil,
                    bundleIdentifier: nil
                )
            )
        )
        guard case let .inserted(item) = outcome,
              let image = item.imageFileName,
              let thumbnail = item.thumbnailFileName else {
            return XCTFail("Expected insert")
        }
        let names = ClipboardAssetNames(
            imageFileName: image,
            thumbnailFileName: thumbnail
        )

        let deleted = try await context.service.delete(id: item.id)
        XCTAssertEqual(deleted, item)
        XCTAssertTrue(context.assets.filesExist(names: names))
        let restored = try await context.service.restore(item)
        XCTAssertEqual(restored, item)
        await context.service.finalizeDeletion(item)
        XCTAssertTrue(context.assets.filesExist(names: names))

        _ = try await context.service.delete(id: item.id)
        await context.service.finalizeDeletion(item)
        XCTAssertFalse(context.assets.filesExist(names: names))
    }

    func testPrepareRegeneratesMissingThumbnailFromOriginal() async throws {
        let normalized = NormalizedClipboardImage(
            pngData: Data([11, 12]),
            thumbnailPNGData: Data([13]),
            widthPixels: 2,
            heightPixels: 1,
            sha256: String(repeating: "e", count: 64)
        )
        let context = try makeContext(normalizedImage: normalized)
        defer { context.remove() }
        let outcome = try await context.service.capture(
            ClipboardSnapshot(
                content: .image(Data([8])),
                copiedAtUTCms: 1,
                sourceApplication: ClipboardSourceApplication(
                    name: nil,
                    bundleIdentifier: nil
                )
            )
        )
        guard case let .inserted(item) = outcome,
              let imageName = item.imageFileName,
              let thumbnailName = item.thumbnailFileName else {
            return XCTFail("Expected insert")
        }
        let thumbnailURL = context.assets.directoryURL
            .appendingPathComponent(thumbnailName)
        try FileManager.default.removeItem(at: thumbnailURL)
        XCTAssertNil(context.assets.readableURL(fileName: thumbnailName))

        let repairingService = ClipboardService(
            store: context.store,
            assetStore: context.assets,
            imageNormalizer: FixedImageNormalizer(result: normalized)
        )
        _ = try await repairingService.prepare(nowUTCms: 2)

        XCTAssertNotNil(context.assets.readableURL(fileName: imageName))
        XCTAssertEqual(
            try context.assets.readData(fileName: thumbnailName),
            normalized.thumbnailPNGData
        )
    }

    private func makeContext(
        normalizedImage: NormalizedClipboardImage = NormalizedClipboardImage(
            pngData: Data([1]),
            thumbnailPNGData: Data([2]),
            widthPixels: 1,
            heightPixels: 1,
            sha256: String(repeating: "a", count: 64)
        ),
        policy: ClipboardRetentionPolicy = .stageThreeDefault
    ) throws -> ClipboardServiceTestContext {
        let directory = try TestTemporaryDirectory.make()
        let store = try JotBloomStore(dataDirectoryURL: directory)
        let assets = try ClipboardAssetStore(dataDirectoryURL: directory)
        let service = ClipboardService(
            store: store,
            assetStore: assets,
            imageNormalizer: FixedImageNormalizer(result: normalizedImage),
            retentionPolicy: policy
        )
        return ClipboardServiceTestContext(
            directory: directory,
            store: store,
            assets: assets,
            service: service
        )
    }
}

private struct FixedImageNormalizer: ClipboardImageNormalizing {
    let result: NormalizedClipboardImage

    func normalize(_ data: Data) throws -> NormalizedClipboardImage {
        result
    }
}

private struct ClipboardServiceTestContext {
    let directory: URL
    let store: JotBloomStore
    let assets: ClipboardAssetStore
    let service: ClipboardService

    func remove() {
        store.close()
        TestTemporaryDirectory.remove(directory)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
