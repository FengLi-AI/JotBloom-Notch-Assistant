import Foundation

/// SSE framing is independent of network chunk and UTF-8 character boundaries.
public struct ChatStreamDecoder {
    public private(set) var done = false
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var frameBytes = 0
    private var totalBytes = 0
    private var finishReason: String?
    private var hasText = false
    public init() {}

    public mutating func feed(_ data: Data) throws -> [String] {
        var texts: [String] = []
        for byte in data { texts += try feed(byte) }
        return texts
    }
    public mutating func feed(_ byte: UInt8) throws -> [String] {
        totalBytes += 1
        guard totalBytes <= 1_048_576 else { throw ChatError.overflow }
        if byte != 10 {
            line.append(byte)
            guard line.count + frameBytes <= 65_536 else { throw ChatError.overflow }
            return []
        }
        if line.last == 13 { line.removeLast() }
        guard let value = String(bytes: line, encoding: .utf8) else { throw ChatError.malformed }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            let data = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true); frameBytes = 0
            guard !data.isEmpty else { return [] }
            guard !done else { throw ChatError.malformed }
            if data == "[DONE]" { done = true; return [] }
            guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                  json["error"] == nil, let choices = json["choices"] as? [[String: Any]] else { throw ChatError.malformed }
            if choices.isEmpty { return [] }
            guard finishReason == nil else { throw ChatError.malformed }
            guard let choice = choices.first, (choice["index"] as? Int ?? 0) == 0,
                  let delta = choice["delta"] as? [String: Any], delta["tool_calls"] == nil,
                  delta["function_call"] == nil else { throw ChatError.malformed }
            if let role = delta["role"] as? String, role != "assistant" { throw ChatError.malformed }
            if let reason = choice["finish_reason"] as? String {
                guard reason == "stop" || reason == "length", finishReason == nil else { throw ChatError.malformed }
                finishReason = reason
            }
            if let content = delta["content"], !(content is NSNull), !(content is String) { throw ChatError.malformed }
            let text = delta["content"] as? String ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
            return text.isEmpty ? [] : [text]
        }
        // Ignore SSE comments and standard non-data fields, but bound the whole frame.
        frameBytes += value.utf8.count + 1
        guard frameBytes <= 65_536 else { throw ChatError.overflow }
        if value == "data" { dataLines.append("") }
        else if value.hasPrefix("data:") {
            var payload = String(value.dropFirst(5))
            if payload.first == " " { payload.removeFirst() }
            dataLines.append(payload)
        }
        return []
    }
    public func completion() throws -> ChatStatus {
        guard done, let finishReason else { throw ChatError.incomplete }
        guard hasText else { throw ChatError.empty }
        return finishReason == "length" ? .length : .complete
    }
}
