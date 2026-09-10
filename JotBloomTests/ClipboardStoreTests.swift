import Foundation
import XCTest
@testable import JotBloomCore

final class ClipboardStoreTests: XCTestCase {
    func testTextInsertAndDuplicateRefreshPreserveOriginalRowAndFavorite() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let firstSource = ClipboardSourceApplication(
            name: "First",
            bundleIdentifier: "com.example.first"
        )
        let secondSource = ClipboardSourceApplication(
            name: "Second",
            bundleIdentifier: "com.example.second"
        )

        let first = try store.upsertClipboardTextSynchronously(
            text: "https://example.com",
            contentType: .link,
            copiedAtUTCms: 10,
            sourceApplication: firstSource
        )
        guard case let .inserted(inserted) = first else {
            return XCTFail("Expected insert")
        }
        try store.performSync { connection in
            let statement = try connection.prepare(
                "UPDATE clipboard_items SET is_favorited_to_prompt = 1 WHERE id = ?",
                operation: "test_favorite"
            )
            try statement.bind(inserted.id, at: 1)
            try statement.executeDone()
        }

        let second = try store.upsertClipboardTextSynchronously(
            text: "https://example.com",
            contentType: .link,
            copiedAtUTCms: 20,
            sourceApplication: secondSource
        )
        guard case let .refreshed(refreshed) = second else {
            return XCTFail("Expected refresh")
        }
        XCTAssertEqual(refreshed.id, inserted.id)
        XCTAssertEqual(refreshed.copiedAtUTCms, 20)
        XCTAssertEqual(refreshed.sourceApplication, secondSource)
        XCTAssertTrue(refreshed.isFavoritedToPrompt)
        XCTAssertEqual(try store.listClipboardItemsSynchronously().count, 1)
    }

    func testTextDeduplicationIsExactForCaseWhitespaceAndUnicodeForm() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let source = ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        let values = [
            "Hello",
            "hello ",
            "e\u{301}",
            "é"
        ]
        for (index, value) in values.enumerated() {
            _ = try store.upsertClipboardTextSynchronously(
                text: value,
                contentType: .text,
                copiedAtUTCms: Int64(index),
                sourceApplication: source
            )
        }

        XCTAssertEqual(try store.listClipboardItemsSynchronously().count, 4)
    }

    func testClipboardTextBindingRoundTripsSpecialCharactersAndNullByte() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let value = "quote' percent%\nemoji🌱\0tail"

        _ = try store.upsertClipboardTextSynchronously(
            text: value,
            contentType: .text,
            copiedAtUTCms: 1,
            sourceApplication: ClipboardSourceApplication(
                name: "App\0Name",
                bundleIdentifier: "com.example.%test"
            )
        )

        let item = try store.listClipboardItemsSynchronously().first
        XCTAssertEqual(item?.textContent, value)
        XCTAssertEqual(item?.sourceApplication.name, "App\0Name")
        XCTAssertEqual(item?.sourceApplication.bundleIdentifier, "com.example.%test")
    }

    func testDuplicateRefreshMovesOldItemToTopWithStableOrdering() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let source = ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        _ = try store.upsertClipboardTextSynchronously(
            text: "first",
            contentType: .text,
            copiedAtUTCms: 1,
            sourceApplication: source
        )
        _ = try store.upsertClipboardTextSynchronously(
            text: "second",
            contentType: .text,
            copiedAtUTCms: 2,
            sourceApplication: source
        )
        _ = try store.upsertClipboardTextSynchronously(
            text: "first",
            contentType: .text,
            copiedAtUTCms: 3,
            sourceApplication: source
        )

        XCTAssertEqual(
            try store.listClipboardItemsSynchronously().compactMap(\.textContent),
            ["first", "second"]
        )
    }

    func testImageInsertMatchDeleteRestoreAndAssetReferencesRoundTrip() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        var store: JotBloomStore? = try JotBloomStore(dataDirectoryURL: directory)
        let identifier = UUID().uuidString.uppercased()
        let names = ClipboardAssetNames(
            imageFileName: "\(identifier).png",
            thumbnailFileName: "\(identifier)-thumb.png"
        )
        let source = ClipboardSourceApplication(
            name: "Preview",
            bundleIdentifier: "com.apple.Preview"
        )
        let inserted = try store!.insertClipboardImageSynchronously(
            names: names,
            byteCount: 123,
            sha256: String(repeating: "a", count: 64),
            widthPixels: 640,
            heightPixels: 480,
            copiedAtUTCms: 50,
            sourceApplication: source
        )
        XCTAssertEqual(
            try store!.matchingClipboardImageSynchronously(
                byteCount: 123,
                sha256: String(repeating: "a", count: 64)
            ),
            inserted
        )
        XCTAssertEqual(
            try store!.referencedClipboardAssetFileNamesSynchronously(),
            [names.imageFileName, names.thumbnailFileName]
        )
        store?.close()

        store = try JotBloomStore(dataDirectoryURL: directory)
        let restoredAcrossLaunch = try store!.listClipboardItemsSynchronously().first
        XCTAssertEqual(restoredAcrossLaunch, inserted)
        let deleted = try store!.deleteClipboardItemSynchronously(id: inserted.id)
        XCTAssertEqual(deleted, inserted)
        XCTAssertTrue(try store!.listClipboardItemsSynchronously().isEmpty)
        XCTAssertEqual(
            try store!.restoreClipboardItemSynchronously(inserted),
            inserted
        )
        store?.close()
    }

    func testRestoreMergesWithEquivalentRecordCreatedDuringUndoWindow() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let source = ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        let outcome = try store.upsertClipboardTextSynchronously(
            text: "same",
            contentType: .text,
            copiedAtUTCms: 1,
            sourceApplication: source
        )
        guard case let .inserted(first) = outcome else {
            return XCTFail("Expected insert")
        }
        _ = try store.deleteClipboardItemSynchronously(id: first.id)
        let replacementOutcome = try store.upsertClipboardTextSynchronously(
            text: "same",
            contentType: .text,
            copiedAtUTCms: 2,
            sourceApplication: source
        )
        guard case let .inserted(replacement) = replacementOutcome else {
            return XCTFail("Expected replacement")
        }

        let restored = try store.restoreClipboardItemSynchronously(first)
        XCTAssertEqual(restored.id, replacement.id)
        XCTAssertEqual(try store.listClipboardItemsSynchronously().count, 1)
    }

    func testImageDedupeCandidateRequiresBothByteCountAndHash() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let source = ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        for marker in ["a", "b"] {
            let identifier = UUID().uuidString.uppercased()
            _ = try store.insertClipboardImageSynchronously(
                names: ClipboardAssetNames(
                    imageFileName: "\(identifier).png",
                    thumbnailFileName: "\(identifier)-thumb.png"
                ),
                byteCount: 100,
                sha256: String(repeating: marker, count: 64),
                widthPixels: 10,
                heightPixels: 10,
                copiedAtUTCms: marker == "a" ? 1 : 2,
                sourceApplication: source
            )
        }

        XCTAssertEqual(try store.listClipboardItemsSynchronously().count, 2)
        XCTAssertNotNil(
            try store.matchingClipboardImageSynchronously(
                byteCount: 100,
                sha256: String(repeating: "a", count: 64)
            )
        )
        XCTAssertNil(
            try store.matchingClipboardImageSynchronously(
                byteCount: 99,
                sha256: String(repeating: "a", count: 64)
            )
        )
    }
}
