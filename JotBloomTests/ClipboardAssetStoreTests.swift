import Foundation
import XCTest
@testable import JotBloomCore

final class ClipboardAssetStoreTests: XCTestCase {
    func testCreatesPrivateDirectoryAndRoundTripsPrivateFiles() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try ClipboardAssetStore(dataDirectoryURL: directory)

        let names = try store.writeNewImage(
            pngData: Data([1, 2, 3]),
            thumbnailPNGData: Data([4, 5])
        )

        XCTAssertTrue(ClipboardAssetStore.isManagedFileName(names.imageFileName))
        XCTAssertTrue(ClipboardAssetStore.isManagedFileName(names.thumbnailFileName))
        XCTAssertEqual(try store.readData(fileName: names.imageFileName), Data([1, 2, 3]))
        XCTAssertEqual(
            try store.readData(fileName: names.thumbnailFileName),
            Data([4, 5])
        )
        XCTAssertEqual(try permissions(at: store.directoryURL), 0o700)
        XCTAssertEqual(
            try permissions(
                at: store.directoryURL.appendingPathComponent(names.imageFileName)
            ),
            0o600
        )
    }

    func testUnsafeFileNameIsRejected() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try ClipboardAssetStore(dataDirectoryURL: directory)

        XCTAssertThrowsError(try store.readData(fileName: "../secret.png")) { error in
            guard case .invalidClipboardAssetName = error as? PersistenceError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try store.readData(fileName: "/tmp/secret.png"))
    }

    func testOriginalWriteFailureDoesNotCreateThumbnail() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try ClipboardAssetStore(dataDirectoryURL: directory)
        let identifier = UUID().uuidString.uppercased()
        let names = ClipboardAssetNames(
            imageFileName: "\(identifier).png",
            thumbnailFileName: "\(identifier)-thumb.png"
        )
        try FileManager.default.createDirectory(
            at: store.directoryURL.appendingPathComponent(
                names.imageFileName,
                isDirectory: true
            ),
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try store.writeImage(
                pngData: Data([1]),
                thumbnailPNGData: Data([2]),
                names: names
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.directoryURL
                    .appendingPathComponent(names.thumbnailFileName).path
            )
        )
    }

    func testSecondWriteFailureRemovesNewOriginal() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try ClipboardAssetStore(dataDirectoryURL: directory)
        let identifier = UUID()
        let names = ClipboardAssetNames(
            imageFileName: "\(identifier.uuidString.uppercased()).png",
            thumbnailFileName: "\(identifier.uuidString.uppercased())-thumb.png"
        )
        let thumbnailURL = store.directoryURL.appendingPathComponent(
            names.thumbnailFileName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: thumbnailURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try store.writeImage(
                pngData: Data([1]),
                thumbnailPNGData: Data([2]),
                names: names
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.directoryURL
                    .appendingPathComponent(names.imageFileName).path
            )
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: thumbnailURL.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testReconcileDeletesOnlyUnreferencedManagedFiles() throws {
        let directory = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(directory) }
        let store = try ClipboardAssetStore(dataDirectoryURL: directory)
        let kept = try store.writeNewImage(
            pngData: Data([1]),
            thumbnailPNGData: Data([2])
        )
        let removed = try store.writeNewImage(
            pngData: Data([3]),
            thumbnailPNGData: Data([4])
        )
        let unrelatedURL = store.directoryURL.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelatedURL)

        XCTAssertEqual(
            try store.reconcile(
                referencedFileNames: [
                    kept.imageFileName,
                    kept.thumbnailFileName
                ]
            ),
            2
        )
        XCTAssertTrue(store.filesExist(names: kept))
        XCTAssertFalse(store.filesExist(names: removed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testSymlinkAssetAndSymlinkDirectoryAreRejected() throws {
        let root = try TestTemporaryDirectory.make()
        defer { TestTemporaryDirectory.remove(root) }
        let store = try ClipboardAssetStore(dataDirectoryURL: root)
        let target = root.appendingPathComponent("target")
        try Data([9]).write(to: target)
        let managedName = "\(UUID().uuidString.uppercased()).png"
        let link = store.directoryURL.appendingPathComponent(managedName)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        XCTAssertThrowsError(try store.readData(fileName: managedName))

        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let linkedData = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedData, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedData.appendingPathComponent("Clipboard"),
            withDestinationURL: otherRoot
        )
        XCTAssertThrowsError(
            try ClipboardAssetStore(dataDirectoryURL: linkedData)
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
