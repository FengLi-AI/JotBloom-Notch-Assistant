import XCTest
@testable import JotBloomCore

final class ChatStreamTests: XCTestCase {
    private func event(_ delta: String, finish: String = "null") -> String {
        "data: {\"choices\":[{\"index\":0,\"delta\":\(delta),\"finish_reason\":\(finish)}]}\n\n"
    }
    func testEveryByteAndEverySplitPreservesChineseEmojiCRLF() throws {
        let text = ": heartbeat\r\n\r\n" + event("{\"role\":\"assistant\"}") + event("{\"content\":\"你好🐈\"}") + event("{}", finish: "\"stop\"") + "data: [DONE]\n\n"
        let bytes = Data(text.replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "\r\r\n", with: "\r\n").utf8)
        for split in 0...bytes.count {
            var decoder = ChatStreamDecoder()
            let first = try decoder.feed(bytes.prefix(split)), second = try decoder.feed(bytes.dropFirst(split))
            XCTAssertEqual((first + second).joined(), "你好🐈"); XCTAssertEqual(try decoder.completion(), .complete)
        }
    }
    func testMultilineDataAndUsageAndReasoningAreHandled() throws {
        var decoder = ChatStreamDecoder()
        let text = "data: {\"choices\":\n" + "data: [{\"delta\":{\"reasoning_content\":\"绝不显示\",\"content\":\"正式回答\"},\"finish_reason\":null}]}\n\n" + event("{}", finish: "\"length\"") + "data: {\"choices\":[],\"usage\":{\"total_tokens\":30}}\n\ndata: [DONE]\n\n"
        XCTAssertEqual(try decoder.feed(Data(text.utf8)).joined(), "正式回答"); XCTAssertEqual(try decoder.completion(), .length)
    }
    func testMissingDoneFinishAndEmptyResponsesAreNotSuccess() throws {
        for text in [event("{\"content\":\"部分\"}"), event("{\"content\":\"部分\"}") + "data: [DONE]\n\n", event("{}", finish: "\"stop\"") + "data: [DONE]\n\n"] {
            var decoder = ChatStreamDecoder(); _ = try decoder.feed(Data(text.utf8)); XCTAssertThrowsError(try decoder.completion())
        }
    }
    func testMalformedFramesToolsRolesAndPostFinishContentRejected() {
        for text in ["data: {bad}\n\n", event("{\"content\":3}"), event("{\"tool_calls\":[]}"), event("{\"role\":\"user\"}"), event("{}", finish: "\"tool_calls\""), event("{}", finish: "\"stop\"") + event("{\"content\":\"late\"}")] {
            var decoder = ChatStreamDecoder(); XCTAssertThrowsError(try decoder.feed(Data(text.utf8)))
        }
    }
    func testOversizedAndInvalidUTF8FramesRejected() throws {
        var oversized = ChatStreamDecoder(); XCTAssertThrowsError(try oversized.feed(Data(String(repeating: "x", count: 65_537).utf8)))
        var invalid = ChatStreamDecoder(); XCTAssertThrowsError(try invalid.feed(Data([0xFF, 0x0A])))
        var total = ChatStreamDecoder()
        let comment = Data((":" + String(repeating: "x", count: 50000) + "\n\n").utf8)
        for _ in 0..<20 { _ = try total.feed(comment) }
        XCTAssertThrowsError(try total.feed(comment))
    }
}
