import Foundation
import Network
import XCTest
@testable import JotBloomCore

final class ChatHTTPTests: XCTestCase {
    func testRealURLSessionDeliversFirstSSEBeforeResponseCompletes() async throws {
        let server = try ChatLoopbackServer(redirect: false)
        let port = try await server.start(); defer { server.stop() }
        let request = try ChatContext.request(configuration: .init(baseURL: "http://127.0.0.1:\(port)/v1", model: "local-fixture"), key: "not-a-real-key", messages: [["role": "user", "content": "fixture"]])
        let recorder = ChatHTTPRecorder()
        let status = try await URLSessionChatTransport().stream(request) { text in await recorder.append(text) }
        let values = await recorder.values
        XCTAssertEqual(status, .complete); XCTAssertEqual(values.map(\.0).joined(), "第一段第二段")
        XCTAssertGreaterThanOrEqual(values.count, 2)
        XCTAssertGreaterThan(values.last!.1 - values.first!.1, 0.15)
    }
    func testRedirectIsRejectedWithoutForwardingCredential() async throws {
        let server = try ChatLoopbackServer(redirect: true)
        let port = try await server.start(); defer { server.stop() }
        let request = try ChatContext.request(configuration: .init(baseURL: "http://127.0.0.1:\(port)/v1", model: "fixture"), key: "not-a-real-key", messages: [])
        do { _ = try await URLSessionChatTransport().stream(request) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? SettingsError, .http(307)) }
    }
}
private actor ChatHTTPRecorder {
    var values: [(String, Double)] = []
    func append(_ text: String) { values.append((text, ProcessInfo.processInfo.systemUptime)) }
}
private final class ChatLoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "JotBloomTests.ChatLoopback")
    private let listener: NWListener
    private let redirect: Bool
    init(redirect: Bool) throws {
        self.redirect = redirect
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] _, _, _, _ in
                if self.redirect {
                    connection.send(content: Data("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:1/must-not-follow\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let first = "data: {\"choices\":[{\"delta\":{\"content\":\"第一段\"}}]}\n\n"
                let second = "data: {\"choices\":[{\"delta\":{\"content\":\"第二段\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((header + self.chunk(first)).utf8), completion: .contentProcessed { _ in })
                self.queue.asyncAfter(deadline: .now() + 0.3) {
                    connection.send(content: Data((self.chunk(second) + "0\r\n\r\n").utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    private func chunk(_ text: String) -> String { String(text.utf8.count, radix: 16) + "\r\n" + text + "\r\n" }
    func stop() { listener.cancel() }
}
