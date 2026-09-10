import Foundation
import XCTest
@testable import JotBloomCore

final class ReleaseCheckerTests: XCTestCase {
    private func payload(_ tags: [(String, Bool, Bool, String)]) throws -> Data {
        try JSONSerialization.data(withJSONObject: tags.map { tag, draft, prerelease, asset in
            ["tag_name": tag, "draft": draft, "prerelease": prerelease,
             "assets": [["name": asset, "state": "uploaded", "size": 100]]] as [String: Any]
        })
    }
    func testNumericVersionOrdering() {
        XCTAssertLessThan(ReleaseVersion("1.0.2")!, ReleaseVersion("v1.0.10")!)
        XCTAssertLessThan(ReleaseVersion("1.9.9")!, ReleaseVersion("2.0.0")!)
        XCTAssertEqual(ReleaseVersion("v1.0.2"), ReleaseVersion("1.0.2"))
    }
    func testRejectMalformedAndPreviewVersions() {
        for value in ["", "1.2", "1.2.3.4", "1.02.3", "1.-1.0", "1.0.0-preview.3", "1.0.２", " 1.0.2"] {
            XCTAssertNil(ReleaseVersion(value), value)
        }
    }
    func testSelectsHighestMacVersionRatherThanPublicationOrder() throws {
        let data = try payload([("v1.0.2", false, false, "JotBloom-1.0.2-universal.dmg"),
                                ("v1.0.10", false, false, "JotBloom-1.0.10-universal.dmg"),
                                ("v1.0.3", false, false, "JotBloom-1.0.3-universal.dmg")])
        let latest = try XCTUnwrap(ReleaseChecker.latest(in: data, statusCode: 200))
        XCTAssertEqual(latest.version.description, "1.0.10")
        XCTAssertEqual(latest.pageURL.absoluteString, "https://github.com/FengLi-AI/JotBloom-Notch-Assistant/releases/tag/v1.0.10")
    }
    func testExcludesDraftPreviewAndWindowsOnlyReleases() throws {
        let data = try payload([("v2.0.0", true, false, "JotBloom-2.0.0-universal.dmg"),
                                ("v3.0.0", false, true, "JotBloom-3.0.0-universal.dmg"),
                                ("v4.0.0", false, false, "JotBloom-4.0.0.exe"),
                                ("v1.0.2", false, false, "JotBloom-1.0.2-universal.dmg")])
        XCTAssertEqual(try ReleaseChecker.latest(in: data, statusCode: 200)?.version.description, "1.0.2")
    }
    func testNoAvailableInstallerDoesNotClaimLatest() throws {
        XCTAssertNil(try ReleaseChecker.latest(in: Data("[]".utf8), statusCode: 200))
        let data = try payload([("v1.0.2", false, false, "JotBloom-1.0.1-universal.dmg")])
        XCTAssertNil(try ReleaseChecker.latest(in: data, statusCode: 200))
        let pending = Data("[{\"tag_name\":\"v1.0.2\",\"draft\":false,\"prerelease\":false,\"assets\":[{\"name\":\"JotBloom-1.0.2-universal.dmg\",\"state\":\"new\",\"size\":0}]}]".utf8)
        XCTAssertNil(try ReleaseChecker.latest(in: pending, statusCode: 200))
    }
    func testHTTPFailuresAndMalformedJSONAreNotUpToDate() {
        for status in [403, 404, 429, 500] {
            XCTAssertThrowsError(try ReleaseChecker.latest(in: Data("[]".utf8), statusCode: status))
        }
        XCTAssertThrowsError(try ReleaseChecker.latest(in: Data("bad response".utf8), statusCode: 200))
    }
}
