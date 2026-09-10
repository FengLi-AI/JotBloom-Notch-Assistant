import XCTest
@testable import JotBloomCore

final class ClipboardContentClassifierTests: XCTestCase {
    func testHttpAndHttpsLinksUseNarrowClassification() {
        XCTAssertEqual(
            ClipboardContentClassifier.classify("https://example.com/path?q=1"),
            .link
        )
        XCTAssertEqual(
            ClipboardContentClassifier.classify("  HTTP://EXAMPLE.COM/a  \n"),
            .link
        )
    }

    func testUnsupportedSchemesAndExplanatoryTextStayPlainText() {
        for value in [
            "mailto:hello@example.com",
            "ftp://example.com/file",
            "jotbloom://item/1",
            "请看 https://example.com",
            "https://one.example https://two.example",
            "https://example.com/a\nb"
        ] {
            XCTAssertEqual(
                ClipboardContentClassifier.classify(value),
                .text,
                value
            )
        }
    }

    func testLinkLengthBoundaryUsesTrimmedCandidate() {
        let prefix = "https://example.com/"
        let accepted = prefix + String(
            repeating: "a",
            count: 2_048 - prefix.count
        )
        XCTAssertEqual(accepted.count, 2_048)
        XCTAssertTrue(ClipboardContentClassifier.isLink(accepted))
        XCTAssertFalse(ClipboardContentClassifier.isLink(accepted + "a"))
    }

    func testEmptyIsSkippedButWhitespaceIsPreservedAsText() {
        XCTAssertNil(ClipboardContentClassifier.classify(""))
        XCTAssertEqual(ClipboardContentClassifier.classify(" \n\t "), .text)
    }

    func testMillionCharacterBoundaryDoesNotTruncate() {
        let accepted = String(repeating: "🌱", count: 1_000_000)
        let rejected = accepted + "🌱"
        XCTAssertEqual(accepted.count, 1_000_000)
        XCTAssertEqual(ClipboardContentClassifier.classify(accepted), .text)
        XCTAssertNil(ClipboardContentClassifier.classify(rejected))
    }

    func testUtf8ByteCountUsesOriginalText() {
        XCTAssertEqual(
            ClipboardContentClassifier.utf8ByteCount(of: " A🌱\n"),
            Int64(" A🌱\n".utf8.count)
        )
    }
}
