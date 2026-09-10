import Foundation
import XCTest
@testable import JotBloomCore

@MainActor
final class ClipboardSnapshotReaderTests: XCTestCase {
    func testConcealedTypeSkipsBeforeAnyPayloadRead() {
        let pasteboard = FakePasteboard(
            changeCount: 1,
            types: [[
                ClipboardPasteboardTypes.concealed,
                ClipboardPasteboardTypes.string
            ]],
            strings: ["0:\(ClipboardPasteboardTypes.string)": "secret"]
        )

        XCTAssertNil(read(from: pasteboard))
        XCTAssertEqual(pasteboard.payloadReadCount, 0)
    }

    func testFileAudioAndMovieSkipBeforePayloadReadEvenWithTextFallback() {
        for unsupported in [
            "public.file-url",
            "com.apple.pasteboard.promised-file-url",
            "public.rtfd",
            "public.pdf",
            "public.mp3",
            "public.mpeg-4"
        ] {
            let pasteboard = FakePasteboard(
                changeCount: 1,
                types: [[unsupported, ClipboardPasteboardTypes.string]],
                strings: ["0:\(ClipboardPasteboardTypes.string)": "fallback"]
            )
            XCTAssertNil(read(from: pasteboard), unsupported)
            XCTAssertEqual(pasteboard.payloadReadCount, 0, unsupported)
        }
    }

    func testOnlyFirstItemIsCaptured() {
        let pasteboard = FakePasteboard(
            changeCount: 1,
            types: [
                [ClipboardPasteboardTypes.string],
                [ClipboardPasteboardTypes.string]
            ],
            strings: [
                "0:\(ClipboardPasteboardTypes.string)": "first",
                "1:\(ClipboardPasteboardTypes.string)": "second"
            ]
        )

        XCTAssertEqual(read(from: pasteboard)?.content, .text("first"))
        XCTAssertEqual(pasteboard.requestedItemIndexes, [0])
    }

    func testImageHasPriorityAndPNGPrecedesTIFFAndJPEG() {
        let pasteboard = FakePasteboard(
            changeCount: 1,
            types: [[
                ClipboardPasteboardTypes.string,
                ClipboardPasteboardTypes.jpeg,
                ClipboardPasteboardTypes.tiff,
                ClipboardPasteboardTypes.png
            ]],
            strings: ["0:\(ClipboardPasteboardTypes.string)": "fallback"],
            data: [
                "0:\(ClipboardPasteboardTypes.png)": Data([1]),
                "0:\(ClipboardPasteboardTypes.tiff)": Data([2]),
                "0:\(ClipboardPasteboardTypes.jpeg)": Data([3])
            ]
        )

        XCTAssertEqual(read(from: pasteboard)?.content, .image(Data([1])))
        XCTAssertEqual(pasteboard.requestedRawTypes, [ClipboardPasteboardTypes.png])
    }

    func testChangeDuringPayloadReadDiscardsUnstableSnapshot() {
        let pasteboard = FakePasteboard(
            changeCount: 1,
            types: [[ClipboardPasteboardTypes.string]],
            strings: ["0:\(ClipboardPasteboardTypes.string)": "unstable"]
        )
        pasteboard.changeCountAfterFirstPayloadRead = 2

        XCTAssertNil(read(from: pasteboard))
        XCTAssertEqual(pasteboard.payloadReadCount, 1)
    }

    func testExpectedChangeCountMismatchDoesNotInspectTypesOrPayload() {
        let pasteboard = FakePasteboard(
            changeCount: 2,
            types: [[ClipboardPasteboardTypes.string]],
            strings: ["0:\(ClipboardPasteboardTypes.string)": "new"]
        )
        let snapshot = ClipboardSnapshotReader().readSnapshot(
            from: pasteboard,
            expectedChangeCount: 1,
            copiedAtUTCms: 100,
            sourceApplication: ClipboardSourceApplication(
                name: nil,
                bundleIdentifier: nil
            )
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(pasteboard.typeReadCount, 0)
        XCTAssertEqual(pasteboard.payloadReadCount, 0)
    }

    private func read(from pasteboard: FakePasteboard) -> ClipboardSnapshot? {
        ClipboardSnapshotReader().readSnapshot(
            from: pasteboard,
            expectedChangeCount: 1,
            copiedAtUTCms: 100,
            sourceApplication: ClipboardSourceApplication(
                name: "Source",
                bundleIdentifier: "com.example.source"
            )
        )
    }
}

@MainActor
private final class FakePasteboard: ClipboardPasteboardAccessing {
    var changeCount: Int
    let types: [[String]]
    let strings: [String: String]
    let storedData: [String: Data]
    var changeCountAfterFirstPayloadRead: Int?
    private(set) var typeReadCount = 0
    private(set) var payloadReadCount = 0
    private(set) var requestedItemIndexes: [Int] = []
    private(set) var requestedRawTypes: [String] = []

    init(
        changeCount: Int,
        types: [[String]],
        strings: [String: String] = [:],
        data: [String: Data] = [:]
    ) {
        self.changeCount = changeCount
        self.types = types
        self.strings = strings
        storedData = data
    }

    func itemTypes() -> [[String]] {
        typeReadCount += 1
        return types
    }

    func string(forType rawType: String, itemAt index: Int) -> String? {
        registerPayloadRead(rawType: rawType, index: index)
        return strings["\(index):\(rawType)"]
    }

    func data(forType rawType: String, itemAt index: Int) -> Data? {
        registerPayloadRead(rawType: rawType, index: index)
        return storedData["\(index):\(rawType)"]
    }

    private func registerPayloadRead(rawType: String, index: Int) {
        payloadReadCount += 1
        requestedItemIndexes.append(index)
        requestedRawTypes.append(rawType)
        if payloadReadCount == 1, let newCount = changeCountAfterFirstPayloadRead {
            changeCount = newCount
        }
    }
}
