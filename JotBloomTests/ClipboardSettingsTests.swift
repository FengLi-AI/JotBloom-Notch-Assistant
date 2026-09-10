import Foundation
import XCTest
@testable import JotBloomCore

private final class CancellingNormalizer: ClipboardImageNormalizing {
    let gate: CapturePermission
    init(_ gate: CapturePermission) { self.gate = gate }
    func normalize(_ data: Data) throws -> NormalizedClipboardImage {
        gate.setAllowed(false); gate.setAllowed(true)
        return .init(pngData: Data([1]), thumbnailPNGData: Data([2]), widthPixels: 1, heightPixels: 1, sha256: String(repeating: "f", count: 64))
    }
}
final class ClipboardSettingsTests: XCTestCase {
    func testSnapshotClearPreservesLaterImageAssets() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let assets = try ClipboardAssetStore(dataDirectoryURL: root)
        let service = ClipboardService(store: store, assetStore: assets, imageNormalizer: TenBImageNormalizer())
        let source = ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        _ = try await service.capture(.init(content: .text("old"), copiedAtUTCms: 1, sourceApplication: source))
        let snapshot = try store.listClipboardItemsSynchronously()
        _ = try await service.capture(.init(content: .image(Data([1])), copiedAtUTCms: 2, sourceApplication: source))
        let success = try await service.clearHistory(snapshot: snapshot)
        XCTAssertTrue(success)
        let remaining = try XCTUnwrap(store.listClipboardItemsSynchronously().first)
        XCTAssertEqual(remaining.contentType, .image)
        XCTAssertNotNil(assets.readableURL(fileName: try XCTUnwrap(remaining.imageFileName)))
        XCTAssertNotNil(assets.readableURL(fileName: try XCTUnwrap(remaining.thumbnailFileName)))
    }
    func testSnapshotClearFailureRollsBackAllRecords() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let service = ClipboardService(store: store, assetStore: try ClipboardAssetStore(dataDirectoryURL: root))
        for n in 0..<3 { _ = try await service.capture(.init(content: .text("item\(n)"), copiedAtUTCms: Int64(n), sourceApplication: .init(name: nil, bundleIdentifier: nil))) }
        let snapshot = try store.listClipboardItemsSynchronously()
        try store.performSync { try $0.execute("CREATE TRIGGER prevent_clear BEFORE DELETE ON clipboard_items WHEN old.id = 1 BEGIN SELECT RAISE(ABORT, 'fixture'); END", operation: "fixture") }
        do { _ = try await service.clearHistory(snapshot: snapshot); XCTFail("must fail") } catch { }
        XCTAssertEqual(try store.listClipboardItemsSynchronously(), snapshot)
    }
    func testOldImageNormalizationCannotCommitAfterToggleCycle() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let assets = try ClipboardAssetStore(dataDirectoryURL: root), gate = CapturePermission()
        let service = ClipboardService(store: store, assetStore: assets, imageNormalizer: CancellingNormalizer(gate), capturePermission: gate)
        let outcome = try await service.capture(.init(content: .image(Data([1])), copiedAtUTCms: 1, sourceApplication: .init(name: nil, bundleIdentifier: nil)))
        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(try store.listClipboardItemsSynchronously().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: assets.directoryURL, includingPropertiesForKeys: nil).isEmpty)
    }
    func testUserGateBlocksTextAndPreservesExistingHistory() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let gate = CapturePermission()
        let service = ClipboardService(store: store, assetStore: try ClipboardAssetStore(dataDirectoryURL: root), capturePermission: gate)
        let first = ClipboardSnapshot(content: .text("original"), copiedAtUTCms: 1, sourceApplication: .init(name: nil, bundleIdentifier: nil))
        _ = try await service.capture(first)
        gate.setAllowed(false)
        let outcome = try await service.capture(.init(content: .text("disabled"), copiedAtUTCms: 2, sourceApplication: first.sourceApplication))
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(try store.listClipboardItemsSynchronously().map(\.textContent), ["original"])
    }
    func testClearPreservesInspirationAndDraftAndRemovesOnlyManagedAssets() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        _ = try store.saveManualInspirationSynchronously(XCTUnwrap(InspirationTextParser.parse("kept inspiration")), timestampUTCms: 1)
        try store.persistDraftSynchronously(kind: .inspiration, content: "kept draft", updatedAtUTCms: 2)
        let assets = try ClipboardAssetStore(dataDirectoryURL: root)
        let service = ClipboardService(store: store, assetStore: assets)
        _ = try await service.capture(.init(content: .text("history"), copiedAtUTCms: 3, sourceApplication: .init(name: nil, bundleIdentifier: nil)))
        let orphan = try assets.writeNewImage(pngData: Data([1]), thumbnailPNGData: Data([2]))
        let unknown = assets.directoryURL.appendingPathComponent("user-keep.txt")
        try Data("kept".utf8).write(to: unknown)
        let usage = try await service.usage()
        XCTAssertEqual(usage.count, 1); XCTAssertEqual(usage.contentBytes, 7); XCTAssertGreaterThan(usage.diskBytes, 0)
        let cleared = try await service.clearHistory(); XCTAssertTrue(cleared)
        XCTAssertEqual(try store.listRecentInspirationsSynchronously().count, 1)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "kept draft")
        XCTAssertTrue(try store.listClipboardItemsSynchronously().isEmpty)
        XCTAssertFalse(assets.filesExist(names: orphan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }
    func testNewRetentionPolicyIsAppliedSeriallyAndDoesNotResurrectDeletedRows() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let service = ClipboardService(store: store, assetStore: try ClipboardAssetStore(dataDirectoryURL: root))
        for index in 0..<5 { _ = try await service.capture(.init(content: .text("\(index)"), copiedAtUTCms: Int64(index), sourceApplication: .init(name: nil, bundleIdentifier: nil))) }
        try await service.applyRetention(.init(maximumCount: 2, maximumAgeMilliseconds: nil, maximumBytes: nil), nowUTCms: 5)
        XCTAssertEqual(try store.listClipboardItemsSynchronously().count, 2)
        try await service.applyRetention(.init(maximumCount: nil, maximumAgeMilliseconds: nil, maximumBytes: nil), nowUTCms: 5)
        _ = try await service.capture(.init(content: .text("next"), copiedAtUTCms: 6, sourceApplication: .init(name: nil, bundleIdentifier: nil)))
        XCTAssertEqual(try store.listClipboardItemsSynchronously().count, 3)
    }
}

private final class TenBImageNormalizer: ClipboardImageNormalizing {
    func normalize(_ data: Data) throws -> NormalizedClipboardImage {
        .init(pngData: Data([1]), thumbnailPNGData: Data([2]), widthPixels: 1, heightPixels: 1, sha256: String(repeating: "a", count: 64))
    }
}
