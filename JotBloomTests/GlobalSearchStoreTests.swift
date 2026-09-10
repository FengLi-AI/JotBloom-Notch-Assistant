import Foundation
import XCTest
@testable import JotBloomCore

final class GlobalSearchStoreTests: XCTestCase {
    func testSearchGroupsRealSourcesExcludesImagesAndKeepsStableOrder() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let source = ClipboardSourceApplication(name: "SearchApp", bundleIdentifier: nil)

        let oldClipboard = try insertedClipboard(
            store: store,
            text: "Alpha old",
            type: .text,
            timestamp: 10,
            source: source
        )
        let newClipboard = try insertedClipboard(
            store: store,
            text: "https://example.com/ALPHA",
            type: .link,
            timestamp: 10,
            source: source
        )
        _ = try store.insertClipboardImageSynchronously(
            names: ClipboardAssetNames(
                imageFileName: "A1B2C3D4-0000-0000-0000-000000000001.png",
                thumbnailFileName: "A1B2C3D4-0000-0000-0000-000000000001-thumb.png"
            ),
            byteCount: 1,
            sha256: String(repeating: "a", count: 64),
            widthPixels: 1,
            heightPixels: 1,
            copiedAtUTCms: 99,
            sourceApplication: ClipboardSourceApplication(
                name: "Alpha Image",
                bundleIdentifier: "com.example.alpha"
            )
        )

        let oldInspiration = try store.saveManualInspirationSynchronously(
            ParsedInspiration(title: "Alpha title", body: "body"),
            timestampUTCms: 20
        )
        let newInspiration = try store.saveManualInspirationSynchronously(
            ParsedInspiration(title: "other", body: "body has alpha near the end"),
            timestampUTCms: 20
        )

        let result = try store.searchAllSynchronously(query: "alpha")

        XCTAssertEqual(result.clipboard.map(\.id.recordID), [
            newClipboard.id,
            oldClipboard.id
        ])
        XCTAssertEqual(result.clipboard.map(\.leadingKind), [.link, .text])
        XCTAssertEqual(result.inspirations.map(\.id.recordID), [
            newInspiration.id,
            oldInspiration.id
        ])
        XCTAssertTrue(result.prompts.isEmpty)
        XCTAssertEqual(result.allResults.count, 4)
        XCTAssertEqual(Set(result.allResults.map(\.id)).count, 4)
        XCTAssertTrue(result.allResults.allSatisfy {
            $0.segments.contains(where: \.isHighlighted)
        })
    }

    func testTitleMatchTakesPriorityAndBodyMatchShowsVisibleContext() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }

        let titleMatch = try store.saveManualInspirationSynchronously(
            ParsedInspiration(
                title: "Needle title",
                body: "Needle body should not become the row"
            ),
            timestampUTCms: 1
        )
        let bodyMatch = try store.saveManualInspirationSynchronously(
            ParsedInspiration(
                title: "Context title",
                body: String(repeating: "前", count: 40) + "needle" + String(repeating: "后", count: 60)
            ),
            timestampUTCms: 2
        )

        let result = try store.searchAllSynchronously(query: "needle")
        let byID = Dictionary(uniqueKeysWithValues: result.inspirations.map {
            ($0.id.recordID, $0)
        })

        XCTAssertEqual(byID[titleMatch.id]?.displayText, "Needle title")
        let bodyText = try XCTUnwrap(byID[bodyMatch.id]?.displayText)
        XCTAssertTrue(bodyText.hasPrefix("…"))
        XCTAssertTrue(bodyText.hasSuffix("…"))
        XCTAssertTrue(bodyText.localizedCaseInsensitiveContains("needle"))
    }

    func testPercentUnderscoreQuotesAndNullAreNotQuerySyntax() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let source = ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        let expected = try insertedClipboard(
            store: store,
            text: "quote' 100%_value\0tail",
            type: .text,
            timestamp: 1,
            source: source
        )
        _ = try insertedClipboard(
            store: store,
            text: "ordinary value",
            type: .text,
            timestamp: 2,
            source: source
        )

        XCTAssertEqual(
            try store.searchAllSynchronously(query: "%_").clipboard.map(\.id.recordID),
            [expected.id]
        )
        XCTAssertEqual(
            try store.searchAllSynchronously(query: "' 100").clipboard.map(\.id.recordID),
            [expected.id]
        )
        XCTAssertEqual(
            try store.searchAllSynchronously(query: "\0tail").clipboard.map(\.id.recordID),
            [expected.id]
        )
    }

    func testWhitespaceOnlyQueryIsEmptyAndSearchDoesNotMutateDatabase() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        _ = try store.saveManualInspirationSynchronously(
            ParsedInspiration(title: "Keep", body: "unchanged"),
            timestampUTCms: 1
        )
        let before = try store.listRecentInspirationsSynchronously()

        XCTAssertEqual(try store.searchAllSynchronously(query: " \n "), .empty)
        _ = try store.searchAllSynchronously(query: "keep")

        XCTAssertEqual(try store.schemaVersionSynchronously(), 7)
        XCTAssertEqual(try store.listRecentInspirationsSynchronously(), before)
    }

    func testClipboardOriginalCanBeReadByIDAndImagesOrMissingRowsReturnNil() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }
        let source = ClipboardSourceApplication(name: nil, bundleIdentifier: nil)
        let text = " exact\ntext \0tail"
        let item = try insertedClipboard(
            store: store,
            text: text,
            type: .text,
            timestamp: 1,
            source: source
        )
        let image = try store.insertClipboardImageSynchronously(
            names: ClipboardAssetNames(
                imageFileName: "B1B2C3D4-0000-0000-0000-000000000001.png",
                thumbnailFileName: "B1B2C3D4-0000-0000-0000-000000000001-thumb.png"
            ),
            byteCount: 1,
            sha256: String(repeating: "b", count: 64),
            widthPixels: 1,
            heightPixels: 1,
            copiedAtUTCms: 2,
            sourceApplication: source
        )

        XCTAssertEqual(
            try store.searchableClipboardTextSynchronously(id: item.id),
            text
        )
        XCTAssertNil(try store.searchableClipboardTextSynchronously(id: image.id))
        _ = try store.deleteClipboardItemSynchronously(id: item.id)
        XCTAssertNil(try store.searchableClipboardTextSynchronously(id: item.id))
    }

    func testSearchReturnsEveryMatchBeyondExistingPageLimits() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try JotBloomStore(dataDirectoryURL: directory)
        defer { store.close() }

        for index in 0..<125 {
            _ = try store.saveManualInspirationSynchronously(
                ParsedInspiration(title: "all-match \(index)", body: "body"),
                timestampUTCms: Int64(index)
            )
        }

        let result = try store.searchAllSynchronously(query: "all-match")
        XCTAssertEqual(result.inspirations.count, 125)
        XCTAssertEqual(Set(result.inspirations.map(\.id)).count, 125)
    }

    private func insertedClipboard(
        store: JotBloomStore,
        text: String,
        type: ClipboardContentType,
        timestamp: Int64,
        source: ClipboardSourceApplication
    ) throws -> ClipboardItem {
        let outcome = try store.upsertClipboardTextSynchronously(
            text: text,
            contentType: type,
            copiedAtUTCms: timestamp,
            sourceApplication: source
        )
        guard case let .inserted(item) = outcome else {
            throw SearchStoreTestError.expectedInsert
        }
        return item
    }
}

private enum SearchStoreTestError: Error {
    case expectedInsert
}
