import Foundation
import XCTest
@testable import JotBloomCore

final class SearchTextMatcherTests: XCTestCase {
    func testNormalizedQueryTrimsEdgesAndRejectsWhitespaceOnlyInput() {
        XCTAssertEqual(SearchTextMatcher.normalizedQuery("  中文  "), "中文")
        XCTAssertEqual(SearchTextMatcher.normalizedQuery("\talpha\n"), "alpha")
        XCTAssertNil(SearchTextMatcher.normalizedQuery(" \n\t "))
        XCTAssertNil(SearchTextMatcher.normalizedQuery(""))
    }

    func testCaseInsensitiveMatchingSupportsUnicodeAndCanonicalEquivalence() {
        XCTAssertTrue(SearchTextMatcher.contains("alpha", in: "ALPHA 中文"))
        XCTAssertTrue(SearchTextMatcher.contains("äP", in: "Äpfel"))
        XCTAssertTrue(SearchTextMatcher.contains("STRASSE", in: "Straße"))
        XCTAssertTrue(SearchTextMatcher.contains("Cafe\u{301}", in: "Café"))
        XCTAssertTrue(SearchTextMatcher.contains("中文", in: "前缀中文后缀"))
    }

    func testSpecialCharactersAreLiteralAndNullByteIsSearchable() {
        let value = "quote' 100%_value \\ emoji🌱\0tail"

        XCTAssertTrue(SearchTextMatcher.contains("%_", in: value))
        XCTAssertTrue(SearchTextMatcher.contains("' 100", in: value))
        XCTAssertTrue(SearchTextMatcher.contains("\\ emoji🌱", in: value))
        XCTAssertTrue(SearchTextMatcher.contains("\0tail", in: value))
        XCTAssertFalse(SearchTextMatcher.contains("not.*regex", in: value))
    }

    func testSegmentsHighlightEveryNonOverlappingMatchAndFlattenWhitespace() throws {
        let segments = try XCTUnwrap(
            SearchTextMatcher.segments(
                in: "Alpha\nalpha\tALPHA",
                matching: "alpha"
            )
        )

        XCTAssertEqual(segments.map(\.text).joined(), "Alpha alpha ALPHA")
        XCTAssertEqual(segments.filter(\.isHighlighted).map(\.text), [
            "Alpha",
            "alpha",
            "ALPHA"
        ])
    }

    func testSnippetKeepsCompleteMatchAndMarksTruncatedEdges() throws {
        let segments = try XCTUnwrap(
            SearchTextMatcher.segments(
                in: "0123456789MATCHabcdefghij",
                matching: "match",
                contextBefore: 3,
                contextAfter: 4
            )
        )

        XCTAssertEqual(segments.map(\.text).joined(), "…789MATCHabcd…")
        XCTAssertEqual(segments.filter(\.isHighlighted).map(\.text), ["MATCH"])
    }

    func testMissingOrEmptyQueryProducesNoSegments() {
        XCTAssertNil(SearchTextMatcher.segments(in: "content", matching: ""))
        XCTAssertNil(SearchTextMatcher.segments(in: "content", matching: "absent"))
    }
}
