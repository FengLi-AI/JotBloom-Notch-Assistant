import XCTest
@testable import JotBloomCore

final class InspirationTextParserTests: XCTestCase {
    func testWhitespaceOnlyInputIsNotSaveable() {
        XCTAssertNil(InspirationTextParser.parse("  \n\t\n"))
    }

    func testSingleLineUsesSameTextForTitleAndBody() throws {
        let parsed = try XCTUnwrap(InspirationTextParser.parse("一条灵感"))

        XCTAssertEqual(parsed.title, "一条灵感")
        XCTAssertEqual(parsed.body, "一条灵感")
    }

    func testMultilineUsesFirstLineAsTitleAndRemainingLinesAsBody() throws {
        let parsed = try XCTUnwrap(
            InspirationTextParser.parse("标题\n正文第一行\n正文第二行")
        )

        XCTAssertEqual(parsed.title, "标题")
        XCTAssertEqual(parsed.body, "正文第一行\n正文第二行")
    }

    func testTitleLimitCountsChineseEnglishEmojiAndComposedCharacters() throws {
        for character in ["字", "A", "🌱", "e\u{301}"] {
            let source = String(repeating: character, count: 31) + "\n正文"
            let parsed = try XCTUnwrap(InspirationTextParser.parse(source))

            XCTAssertEqual(parsed.title.count, 30)
            XCTAssertEqual(parsed.title, String(repeating: character, count: 30))
            XCTAssertEqual(parsed.body, "正文")
        }
    }

    func testLeadingEmptyFirstLineRemainsAnEmptyTitle() throws {
        let parsed = try XCTUnwrap(InspirationTextParser.parse("\n正文"))

        XCTAssertEqual(parsed.title, "")
        XCTAssertEqual(parsed.body, "正文")
    }

    func testDomainEnumValuesMatchVersionOneSchemaContract() {
        XCTAssertEqual(
            InspirationCategory.allCases.map(\.rawValue),
            ["文章类", "作品类", "产品类", "idea"]
        )
        XCTAssertEqual(ValueSource.allCases.map(\.rawValue), ["ai", "fallback", "user"])
        XCTAssertEqual(InspirationSource.allCases.map(\.rawValue), ["manual", "ai_chat"])
        XCTAssertEqual(DraftKind.allCases.map(\.rawValue), ["inspiration", "ai_chat"])
    }
}
