import Foundation
import XCTest
@testable import JotBloomCore

private actor ScriptedTransport: ConnectionTransport {
    var responses: [Result<(Data, Int), Error>]
    var requests: [URLRequest] = []
    init(_ responses: [Result<(Data, Int), Error>]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return try responses.removeFirst().get()
    }
}
final class ConnectionTesterTests: XCTestCase {
    private let config = ModelConfiguration(baseURL: "https://fixture.invalid/v1/chat/completions", model: "fixture-model")
    private let success = Data(#"{"choices":[{"message":{"role":"assistant","content":"测试成功"}}],"usage":{"total_tokens":12}}"#.utf8)
    func testRequestContractAndValidReply() async throws {
        let transport = ScriptedTransport([.success((success, 200))])
        let result = try await ConnectionTester(transport: transport).test(configuration: config, key: "fixture-key")
        XCTAssertEqual(result.attempts, 1)
        XCTAssertEqual(result.totalTokens, 12)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://fixture.invalid/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 128); XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": "Reply with OK."]])
        XCTAssertEqual(Set(body.keys), ["model", "stream", "max_tokens", "messages"])
    }
    func testAuthenticationRateLimitRedirectAndOtherClientErrorsNeverRetry() async {
        for status in [301, 302, 400, 401, 403, 404, 429] {
            let transport = ScriptedTransport([.success((Data("secret-error-body".utf8), status))])
            do { _ = try await ConnectionTester(transport: transport).test(configuration: config, key: "fixture"); XCTFail() }
            catch { XCTAssertEqual(error as? SettingsError, .http(status)); XCTAssertFalse(error.localizedDescription.contains("secret-error-body")) }
            let count = await transport.requests.count; XCTAssertEqual(count, 1)
        }
    }
    func testServerNetworkAndTimeoutRetryOnce() async throws {
        for failure: Result<(Data, Int), Error> in [.success((Data(), 503)), .failure(URLError(.timedOut)), .failure(URLError(.notConnectedToInternet))] {
            let transport = ScriptedTransport([failure, .success((success, 200))])
            let result = try await ConnectionTester(transport: transport).test(configuration: config, key: "fixture")
            XCTAssertEqual(result.attempts, 2)
        }
    }
    func testRetriesAreBoundedAtTwo() async {
        let transport = ScriptedTransport([.success((Data(), 500)), .success((Data(), 502))])
        do { _ = try await ConnectionTester(transport: transport).test(configuration: config, key: "fixture"); XCTFail() }
        catch { XCTAssertEqual(error as? SettingsError, .http(502)) }
        let count = await transport.requests.count; XCTAssertEqual(count, 2)
    }
    func testMalformedEmptyAndOversizeResponsesNeverRetry() async {
        let responses = [Data("<html>ok</html>".utf8), Data(#"{"choices":[]}"#.utf8), Data(repeating: 65, count: 262_145)]
        for data in responses {
            let transport = ScriptedTransport([.success((data, 200))])
            do { _ = try await ConnectionTester(transport: transport).test(configuration: config, key: "fixture"); XCTFail() }
            catch { XCTAssertEqual(error as? SettingsError, data.count > 262_144 ? .responseTooLarge : .responseInvalid) }
            let count = await transport.requests.count; XCTAssertEqual(count, 1)
        }
    }
    func testInvalidConfigAndEmptyKeyDoNotSend() async {
        let transport = ScriptedTransport([])
        for key in ["", " ", "bad\nheader"] {
            do { _ = try await ConnectionTester(transport: transport).test(configuration: config, key: key); XCTFail() }
            catch { XCTAssertEqual(error as? SettingsError, .missingKey) }
        }
        let count = await transport.requests.count; XCTAssertEqual(count, 0)
    }
    func testDeepSeekOptionsAreRestrictedToOfficialV4Endpoint() async throws {
        for (base, model, expected) in [
            ("https://api.deepseek.com", "deepseek-v4-flash", true),
            ("https://api.deepseek.com/v1/", "deepseek-v4-pro", true),
            ("https://api.deepseek.com.attacker.invalid", "deepseek-v4-flash", false),
            ("https://gateway.invalid/v1", "deepseek-v4-flash", false),
            ("https://api.deepseek.com", "other-model", false)
        ] {
            let transport = ScriptedTransport([.success((success, 200))])
            _ = try await ConnectionTester(transport: transport).test(configuration: .init(baseURL: base, model: model), key: "fixture")
            let requests = await transport.requests
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], expected ? "disabled" : nil)
            XCTAssertEqual(body["max_tokens"] as? Int, 128)
        }
    }
    func testReasoningTruncationAndEmptyAnswerAreDistinctAndNeverRetried() async {
        for (reply, expected) in [
            (#"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"","reasoning_content":"private reasoning"}}]}"#, SettingsError.responseTruncated),
            (#"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"OK"}}]}"#, .responseTruncated),
            (#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":null,"reasoning_content":"private reasoning"}}]}"#, .reasoningOnlyResponse),
            (#"{"choices":[{"message":{"role":"assistant","content":" "}}]}"#, .emptyResponse)
        ] {
            let transport = ScriptedTransport([.success((Data(reply.utf8), 200))])
            do { _ = try await ConnectionTester(transport: transport).test(configuration: config, key: "fixture"); XCTFail("must not pass without a complete answer") }
            catch { XCTAssertEqual(error as? SettingsError, expected); XCTAssertFalse(error.localizedDescription.contains("private reasoning")) }
            let calls = await transport.requests.count; XCTAssertEqual(calls, 1)
        }
    }
    func testCancellationNeverRetries() async {
        let transport = ScriptedTransport([.failure(URLError(.cancelled))])
        do { _ = try await ConnectionTester(transport: transport).test(configuration: config, key: "fixture"); XCTFail() }
        catch { XCTAssertEqual(error as? SettingsError, .cancelled) }
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }
    func testTransportPrivacyAndTotalTimeoutConfiguration() {
        let configuration = URLSessionConnectionTransport.configuration()
        XCTAssertNil(configuration.urlCache); XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage); XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 10)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
    }
    func testRedirectDelegateAlwaysRejectsReplacementURL() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://original.invalid")!, redirected = URL(string: "https://untrusted.invalid")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirected.absoluteString])!
        var called = false
        NoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: redirected)) { request in
            called = true; XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }
}
