import Foundation

public protocol ConnectionTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct URLSessionConnectionTransport: ConnectionTransport {
    public init() {}
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        return config
    }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let config = Self.configuration()
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SettingsError.responseInvalid }
        guard (200...299).contains(http.statusCode) else { return (Data(), http.statusCode) }
        if response.expectedContentLength > 262_144 { throw SettingsError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 262_144 else { throw SettingsError.responseTooLarge }
            data.append(byte)
        }
        return (data, http.statusCode)
    }
}

public struct ConnectionTestResult: Equatable, Sendable {
    public let attempts: Int
    public let elapsedMilliseconds: Double
    public let totalTokens: Int?
}

/// Provider-specific options apply only to our bounded, non-streaming short tasks.
enum ShortModelTask {
    static let maximumOutputTokens = 128
    static func applyOptions(to body: inout [String: Any], baseURL: String, model: String) {
        body["max_tokens"] = maximumOutputTokens
        if URL(string: baseURL)?.host?.lowercased() == "api.deepseek.com",
           model.lowercased().hasPrefix("deepseek-v4-") {
            body["thinking"] = ["type": "disabled"]
        }
    }

    static func assistantText(in json: [String: Any]) throws -> String {
        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any],
              message["role"] as? String == "assistant" else { throw SettingsError.responseInvalid }
        // Never accept partial output (even a plausible short title) as a completed answer.
        if choice["finish_reason"] as? String == "length" { throw SettingsError.responseTruncated }
        let text = message["content"] as? String ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let reasoning = message["reasoning_content"] as? String,
               !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SettingsError.reasoningOnlyResponse
            }
            throw SettingsError.emptyResponse
        }
        return text
    }
}

public struct ConnectionTester: Sendable {
    private let transport: any ConnectionTransport
    public init(transport: any ConnectionTransport = URLSessionConnectionTransport()) { self.transport = transport }
    public func test(configuration: ModelConfiguration, key: String) async throws -> ConnectionTestResult {
        let base = try ModelEndpoint.normalize(configuration.baseURL)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw SettingsError.missingModel }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.contains("\r"), !key.contains("\n") else { throw SettingsError.missingKey }
        var request = URLRequest(url: URL(string: base + "/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["model": model, "stream": false,
                                 "messages": [["role": "user", "content": "Reply with OK."]]]
        ShortModelTask.applyOptions(to: &body, baseURL: base, model: model)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = ProcessInfo.processInfo.systemUptime
        for attempt in 1...2 {
            try Task.checkCancellation()
            do {
                let (data, status) = try await transport.send(request)
                try Task.checkCancellation()
                guard (200...299).contains(status) else { throw SettingsError.http(status) }
                guard data.count <= 262_144 else { throw SettingsError.responseTooLarge }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SettingsError.responseInvalid }
                _ = try ShortModelTask.assistantText(in: json)
                let total = (json["usage"] as? [String: Any])?["total_tokens"] as? Int
                return ConnectionTestResult(attempts: attempt, elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                            totalTokens: total.flatMap { $0 >= 0 ? $0 : nil })
            } catch {
                let mapped: SettingsError
                if Task.isCancelled || error is CancellationError { throw SettingsError.cancelled }
                if let known = error as? SettingsError { mapped = known }
                else if let url = error as? URLError { mapped = url.code == .timedOut ? .timeout : url.code == .cancelled ? .cancelled : .network }
                else { mapped = .network }
                let retry: Bool
                switch mapped { case .network, .timeout: retry = true; case .http(let status): retry = status >= 500 && status <= 599; default: retry = false }
                if attempt == 2 || !retry { throw mapped }
            }
        }
        throw SettingsError.network
    }
}
