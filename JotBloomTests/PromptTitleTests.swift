import Foundation
import XCTest
@testable import JotBloomCore

private actor TitleTransport: ConnectionTransport {
    var requests: [URLRequest] = []
    let status: Int
    let delay: UInt64
    let response: String
    init(status: Int = 200, delay: UInt64 = 0, response: String = #"{"choices":[{"message":{"role":"assistant","content":"内容整理助手"}}]}"#) {
        self.status = status; self.delay = delay; self.response = response
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return (Data(response.utf8), status)
    }
}
private actor TitleCredentials: CredentialStoring {
    var interactiveReads = 0, silentReads = 0
    let deny: Bool
    init(deny: Bool = false) { self.deny = deny }
    func read(_ slot: ModelSlot) -> String? { interactiveReads += 1; return "test-only-key" }
    func readWithoutInteraction(_ slot: ModelSlot) throws -> String? { silentReads += 1; if deny { throw SettingsError.credentialLocked }; return "test-only-key" }
    func write(_ secret: String, slot: ModelSlot) {}
    func remove(_ slot: ModelSlot) {}
}
final class PromptTitleTests: XCTestCase {
    func testParserBoundaries() {
        XCTAssertEqual(PromptTitleService.parse(" “写作润色助手。” \n"), "写作润色助手")
        XCTAssertNil(PromptTitleService.parse("标题\n解释"))
        XCTAssertNil(PromptTitleService.parse(" \n"))
        XCTAssertNil(PromptTitleService.parse(String(repeating: "字", count: 21)))
        for count in [1,5,10,11,19,20] { XCTAssertEqual(PromptTitleService.parse(String(repeating: "字", count: count))?.count, min(count, 10)) }
    }
    func testExactTemplateRequestAndTruncation() async throws {
        let transport = TitleTransport()
        let title = try await PromptTitleService(transport: transport).title(content: String(repeating: "🪷", count: 2005), configuration: ModelConfiguration(baseURL: "https://fixture.invalid/v1", model: "title-model"), key: "test-only-key")
        XCTAssertEqual(title, "内容整理助手")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2); XCTAssertEqual(messages[0]["content"], PromptTitleService.systemPrompt)
        XCTAssertEqual(messages[1]["content"]?.count, 2000)
        XCTAssertEqual(json["temperature"] as? Double, 0.3); XCTAssertEqual(json["max_tokens"] as? Int, 128)
        XCTAssertNil(json["thinking"])
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
    }
    func testAllHTTPFailuresUseSingleAttempt() async throws {
        for status in [301,302,401,429,500,503] {
            let transport = TitleTransport(status: status)
            do { _ = try await PromptTitleService(transport: transport).title(content: "sample", configuration: ModelConfiguration(baseURL: "https://fixture.invalid", model: "fixture"), key: "test-only-key"); XCTFail() }
            catch { XCTAssertEqual(error as? SettingsError, .http(status)) }
            let count = await transport.requests.count; XCTAssertEqual(count, 1)
        }
    }
    func testDeepSeekTitleDisablesThinkingAndUsesFinalContentOnly() async throws {
        let transport = TitleTransport(response: #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"工作周报整理","reasoning_content":"不可作为标题的思考"}}]}"#)
        let title = try await PromptTitleService(transport: transport).title(content: "整理每周工作", configuration: .init(baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-flash"), key: "fixture")
        XCTAssertEqual(title, "工作周报整理")
        let requests = await transport.requests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertEqual(body["max_tokens"] as? Int, 128)
    }
    @MainActor func testTruncatedTitleKeepsOriginalAndReportsFailure() async throws {
        let dir = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(dir) }
        let store = try JotBloomStore(dataDirectoryURL: dir); defer { store.close() }
        let saved = try await store.saveInputPrompt(content: "原文绝不能丢失", token: "truncated", timestamp: 1)
        let transport = TitleTransport(response: #"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"看似可用标题"}}]}"#)
        var settings = AppSettings(); settings.main = .init(baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash")
        let queue = PromptTitleCoordinator(store: store, credentials: TitleCredentials(), settings: { settings }, service: .init(transport: transport))
        var failure: SettingsError?
        queue.onFailure = { id, reason in XCTAssertEqual(id, saved.id); failure = reason }
        queue.enqueue(saved.id)
        for _ in 0..<100 { if queue.activeCount == 0 { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(failure, .responseTruncated)
        XCTAssertEqual(try store.promptSynchronously(id: saved.id)?.titleSource, .fallback)
        XCTAssertEqual(try store.promptSynchronously(id: saved.id)?.content, "原文绝不能丢失")
        let calls = await transport.requests.count; XCTAssertEqual(calls, 1)
    }
    @MainActor func testDeniedSilentAccessNeverPromptsOrSends() async throws {
        let dir = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(dir) }
        let store = try JotBloomStore(dataDirectoryURL: dir); defer { store.close() }
        let row = try await store.saveInputPrompt(content: "私有内容", token: "t", timestamp: 1)
        let credentials = TitleCredentials(deny: true), transport = TitleTransport()
        var settings = AppSettings(); settings.main = ModelConfiguration(baseURL: "https://fixture.invalid", model: "test")
        let queue = PromptTitleCoordinator(store: store, credentials: credentials, settings: { settings }, service: PromptTitleService(transport: transport))
        var failure: SettingsError?
        queue.onFailure = { _, error in failure = error }
        queue.enqueue(row.id)
        for _ in 0..<100 { if queue.activeCount == 0 { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        let reads = await credentials.interactiveReads, silent = await credentials.silentReads, calls = await transport.requests.count
        XCTAssertEqual(reads, 0); XCTAssertEqual(silent, 1); XCTAssertEqual(calls, 0)
        XCTAssertEqual(failure, .credentialLocked)
        XCTAssertEqual(try store.promptSynchronously(id: row.id)?.titleSource, .fallback)
    }
    @MainActor func testQueueIsBoundedAndInvalidationRejectsOldResults() async throws {
        let dir = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(dir) }
        let store = try JotBloomStore(dataDirectoryURL: dir); defer { store.close() }
        var ids: [Int64] = []
        for n in 0..<40 { ids.append(try await store.saveInputPrompt(content: "内容\(n)", token: "\(n)", timestamp: Int64(n)).id) }
        let transport = TitleTransport(delay: 300_000_000), credentials = TitleCredentials()
        var settings = AppSettings(); settings.main = ModelConfiguration(baseURL: "https://fixture.invalid", model: "test")
        let queue = PromptTitleCoordinator(store: store, credentials: credentials, settings: { settings }, service: PromptTitleService(transport: transport))
        for id in ids { queue.enqueue(id) }
        XCTAssertEqual(queue.activeCount, 2); XCTAssertEqual(queue.pendingCount, 32)
        try await Task.sleep(nanoseconds: 20_000_000)
        await queue.drain()
        XCTAssertEqual(queue.activeCount, 0); XCTAssertEqual(queue.pendingCount, 0)
        for id in ids { XCTAssertEqual(try store.promptSynchronously(id: id)?.titleSource, .fallback) }
        let count = await transport.requests.count; XCTAssertLessThanOrEqual(count, 2)
    }
    @MainActor func testSuccessfulBackgroundTitleDoesNotChangeContent() async throws {
        let dir = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(dir) }
        let store = try JotBloomStore(dataDirectoryURL: dir); defer { store.close() }
        let saved = try await store.saveInputPrompt(content: "完整\n原文", token: "t", timestamp: 1)
        let transport = TitleTransport(), credentials = TitleCredentials()
        var settings = AppSettings(); settings.main = ModelConfiguration(baseURL: "https://fixture.invalid", model: "test")
        let queue = PromptTitleCoordinator(store: store, credentials: credentials, settings: { settings }, service: PromptTitleService(transport: transport))
        queue.enqueue(saved.id)
        for _ in 0..<100 { if queue.activeCount == 0 { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(try store.promptSynchronously(id: saved.id)?.title, "内容整理助手")
        XCTAssertEqual(try store.promptSynchronously(id: saved.id)?.content, "完整\n原文")
        XCTAssertEqual(try store.promptSynchronously(id: saved.id)?.createdAtUTCms, 1)
    }
}
