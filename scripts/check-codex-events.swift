import Foundation

@main
struct EventChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jotbloom-events-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), started = now.addingTimeInterval(-1)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ object: [String: Any]) throws -> Data { var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10); return data }
        func metadata(_ thread: String, source: Any = "vscode") throws -> Data { try line(["type": "session_meta", "payload": ["id": thread, "source": source, "originator": "codex_vscode"]]) }
        func complete(_ turn: String, at date: Date = Date(), type: String = "task_complete") throws -> Data {
            try line(["type": "event_msg", "timestamp": iso.string(from: date), "payload": ["type": type, "turn_id": turn, "completed_at": Int(date.timeIntervalSince1970), "last_agent_message": "只在内存中跳过的正文"]])
        }
        func append(_ data: Data, to url: URL) throws { let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.seekToEnd(); try file.write(contentsOf: data) }
        var count = 0
        func check(_ condition: Bool, _ message: String) { count += 1; guard condition else { fatalError(message) } }
        let file = root.appendingPathComponent("sessions/a.jsonl")
        try (metadata("thread-a") + complete("history")).write(to: file)
        let reader = CodexCompletionReader(root: root, startedAt: started)
        check(reader.poll(now: now).isEmpty, "startup must skip existing history")
        try append(complete("one", at: now), to: file)
        let first = reader.poll(now: now)
        check(first.count == 1 && first[0].host == .vscode, "real task_complete schema")
        check(reader.poll(now: now).isEmpty, "idle poll cannot replay")
        try append(complete("one", at: now), to: file)
        check(reader.poll(now: now).isEmpty, "thread/turn deduplication")
        let split = try complete("split", at: now), half = split.count / 2
        try append(Data(split.prefix(half)), to: file)
        check(reader.poll(now: now).isEmpty, "partial line cannot signal completion")
        try append(Data(split.dropFirst(half)), to: file)
        check(reader.poll(now: now).map(\.turn) == ["split"], "split utf8 line completes once")
        try append(complete("abort", at: now, type: "turn_aborted"), to: file)
        try append(line(["type": "response_item", "payload": ["type": "task_complete", "turn_id": "fake"]]), to: file)
        check(reader.poll(now: now).isEmpty, "interrupt and assistant text are not completion events")
        let old = root.appendingPathComponent("sessions/old.jsonl")
        try (metadata("old") + complete("old", at: now.addingTimeInterval(-120))).write(to: old)
        check(reader.poll(now: now).isEmpty, "newly discovered historical file must not replay")
        let child = root.appendingPathComponent("sessions/child.jsonl")
        try (metadata("child", source: ["subagent": ["thread_spawn": [:]]]) + complete("child", at: now)).write(to: child)
        check(reader.poll(now: now).isEmpty, "subagent stop is not user turn completion")
        let created = root.appendingPathComponent("sessions/created.jsonl")
        try (metadata("new") + complete("new", at: now)).write(to: created)
        check(reader.poll(now: now).map(\.turn) == ["new"], "new session after startup is observed")
        // Truncation, big tool output, then completion; bounded reads must retain boundaries.
        try metadata("thread-b").write(to: file)
        _ = reader.poll(now: now)
        try append(Data(repeating: 65, count: 6 * 1024 * 1024) + Data([10]) + complete("after-large", at: now), to: file)
        var largeEvents: [CodexCompletion] = []
        for _ in 0..<5 { largeEvents += reader.poll(now: now) }
        check(largeEvents.map(\.turn) == ["after-large"], "large records cannot poison the next completion")
        reader.reset(now: now); check(reader.poll(now: now).isEmpty, "resume must rebaseline")
        var history = CodexForegroundHistory()
        history.record("com.microsoft.VSCode", at: started)
        check(!history.shouldNotify(first[0], now: now), "foreground Codex must not alert")
        history.record("com.google.Chrome", at: now.addingTimeInterval(0.1))
        check(!history.shouldNotify(first[0], now: now.addingTimeInterval(0.2)), "switch after foreground completion does not turn it into a background result")
        let background = CodexCompletion(thread: "a", turn: "b", completedAt: now.addingTimeInterval(0.15), host: .vscode)
        check(history.shouldNotify(background, now: now.addingTimeInterval(0.2)), "background completion alerts")
        history.record("com.microsoft.VSCode", at: now.addingTimeInterval(0.25))
        check(!history.shouldNotify(background, now: now.addingTimeInterval(0.3)), "returning before delivery suppresses pending notice")
        check(!history.shouldNotify(background, now: now.addingTimeInterval(120)), "stale results must not alert")
        print("Codex completion adapter: \(count)/\(count) passed")
    }
}
