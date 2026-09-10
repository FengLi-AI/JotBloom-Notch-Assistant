import Foundation
import XCTest
@testable import JotBloomCore

final class DataDirectoryResolverTests: XCTestCase {
    func testProductionDirectoryUsesApplicationSupportAndBundleIdentifier() throws {
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )

        let result = try DataDirectoryResolver.productionDirectory()

        XCTAssertEqual(
            result.path,
            applicationSupport
                .appendingPathComponent(DataDirectoryResolver.bundleIdentifier)
                .standardizedFileURL
                .path
        )
    }

    func testDebugDirectoryAcceptsStrictTemporaryDescendant() throws {
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("jotbloom-debug-\(UUID().uuidString)")

        let result = try DataDirectoryResolver.validatedDebugDirectory(
            path: candidate.path
        )

        XCTAssertEqual(
            result.path,
            candidate.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func testDebugDirectoryRejectsRelativeAndBroadPaths() {
        for path in ["relative/path", "/", "/private/tmp2/jotbloom"] {
            XCTAssertThrowsError(
                try DataDirectoryResolver.validatedDebugDirectory(path: path),
                "Expected rejection for \(path)"
            )
        }
    }

    func testDebugDirectoryRejectsSymlinkThatEscapesTemporaryRoot() throws {
        let parent = try TestTemporaryDirectory.make(prefix: "jotbloom-symlink")
        defer { TestTemporaryDirectory.remove(parent) }
        let link = parent.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
        )

        XCTAssertThrowsError(
            try DataDirectoryResolver.validatedDebugDirectory(path: link.path)
        )
    }

    func testEphemeralDirectoryIsUniqueAndInsideSystemTemporaryDirectory() {
        let first = DataDirectoryResolver.makeEphemeralDirectory(prefix: "jotbloom-smoke")
        let second = DataDirectoryResolver.makeEphemeralDirectory(prefix: "jotbloom-smoke")
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let prefix = temporaryRoot.path.hasSuffix("/")
            ? temporaryRoot.path
            : temporaryRoot.path + "/"

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.resolvingSymlinksInPath().path.hasPrefix(prefix))
        XCTAssertTrue(second.resolvingSymlinksInPath().path.hasPrefix(prefix))
    }
}
