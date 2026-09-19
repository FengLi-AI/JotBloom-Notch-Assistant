import Foundation

enum CodexHost: String {
    case vscode, desktop, terminal
    var bundleIDs: Set<String> {
        switch self {
        case .vscode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.vscodium"]
        case .desktop: return ["com.openai.codex"]
        // An integrated terminal is also visible when its editor is foreground.
        case .terminal: return ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
        }
    }
    static func parse(_ metadata: [String: Any]) -> CodexHost? {
        guard let source = metadata["source"] as? String else { return nil } // Excludes subagents.
        let origin = (metadata["originator"] as? String ?? "").lowercased()
        if origin.contains("desktop") { return .desktop }
        if source == "vscode" || origin.contains("vscode") { return .vscode }
        if source == "cli" || source == "exec" { return .terminal }
        return nil
    }
}

struct CodexCompletion {
    let thread: String
    let turn: String
    let completedAt: Date
    let host: CodexHost
    var key: String { thread + "/" + turn }
}

/// Reads only newly appended records; never writes Codex config or session files.
/// This adapter matches the installed Codex 0.154 session event schema. Unknown
/// schemas fail closed rather than guessing completion from text or inactivity.
final class CodexCompletionReader {
    private struct Cursor {
        var offset: UInt64
        var pending = Data()
        var discarding = false
        var thread: String?
        var host: CodexHost?
        var inode: UInt64
    }
    private var cursors: [URL: Cursor] = [:]
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private let root: URL
    private var startedAt: Date
    private(set) var available = false
    private(set) var hasSessions = false
    private(set) var failed = false
    private var primed = false
    private let dateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return parser
    }()
    init(root: URL, startedAt: Date = Date()) { self.root = root; self.startedAt = startedAt }

    func reset(now: Date = Date()) { cursors.removeAll(); seen.removeAll(); seenOrder.removeAll(); startedAt = now; primed = false }

    func poll(now: Date = Date()) -> [CodexCompletion] {
        let fm = FileManager.default, sessions = root.appendingPathComponent("sessions", isDirectory: true)
        available = fm.isReadableFile(atPath: sessions.path); failed = false
        guard available, let enumerator = fm.enumerator(at: sessions, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { [weak self] _, _ in self?.failed = true; return true }) else { return [] }
        var events: [CodexCompletion] = [], files = Set<URL>(), budget = 8 * 1024 * 1024
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.insert(url)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? UInt64 else { failed = true; continue }
            let inode = attrs[.systemFileNumber] as? UInt64 ?? 0
            var cursor = cursors[url] ?? Cursor(offset: primed ? 0 : size, inode: inode)
            if cursor.inode != inode || cursor.offset > size { cursor = Cursor(offset: 0, inode: inode) }
            if let existing = cursors[url], existing.inode == inode, existing.offset == size { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { failed = true; continue }
            defer { try? handle.close() }
            if cursors[url] == nil || cursor.thread == nil {
                if let header = try? handle.read(upToCount: 512 * 1024), let newline = header.firstIndex(of: 10) {
                    applyMetadata(Data(header[..<newline]), to: &cursor)
                }
            }
            if size > cursor.offset && budget > 0 {
                do {
                    try handle.seek(toOffset: cursor.offset)
                    let count = min(budget, Int(min(size - cursor.offset, 2 * 1024 * 1024)))
                    let bytes = try handle.read(upToCount: count) ?? Data()
                    budget -= bytes.count; cursor.offset += UInt64(bytes.count)
                    consume(bytes, cursor: &cursor, now: now, events: &events)
                } catch { failed = true }
            }
            cursors[url] = cursor
        }
        cursors = cursors.filter { files.contains($0.key) }; hasSessions = !files.isEmpty; primed = true
        return events.sorted { $0.completedAt < $1.completedAt }
    }

    private func consume(_ data: Data, cursor: inout Cursor, now: Date, events: inout [CodexCompletion]) {
        cursor.pending.append(data)
        while let newline = cursor.pending.firstIndex(of: 10) {
            let line = Data(cursor.pending[..<newline]); cursor.pending.removeSubrange(...newline)
            if cursor.discarding { cursor.discarding = false; continue }
            if cursor.thread == nil { applyMetadata(line, to: &cursor) }
            // Avoid decoding model/tool contents when no completion marker exists.
            guard line.range(of: Data("\"task_complete\"".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any], payload["type"] as? String == "task_complete",
                  let turn = payload["turn_id"] as? String, !turn.isEmpty,
                  let thread = cursor.thread, let host = cursor.host,
                  let timestamp = payload["completed_at"] as? String ?? object["timestamp"] as? String,
                  let date = dateParser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp),
                  date >= startedAt, now.timeIntervalSince(date) < 60, date.timeIntervalSince(now) < 5 else { continue }
            let event = CodexCompletion(thread: thread, turn: turn, completedAt: date, host: host)
            guard seen.insert(event.key).inserted else { continue }
            seenOrder.append(event.key)
            if seenOrder.count > 1024 { seen.remove(seenOrder.removeFirst()) }
            events.append(event)
        }
        // Large tool messages can span many reads. Discard through their newline,
        // never interpret a fragment as a new event or retain an unbounded buffer.
        if cursor.pending.count > 4 * 1024 * 1024 { cursor.pending.removeAll(keepingCapacity: false); cursor.discarding = true }
    }
    private func applyMetadata(_ data: Data, to cursor: inout Cursor) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String else { return }
        cursor.thread = id; cursor.host = CodexHost.parse(payload)
    }
}

struct CodexForegroundHistory {
    private var changes: [(Date, String?)] = []
    mutating func record(_ bundle: String?, at date: Date = Date()) {
        if changes.last?.1 == bundle && !changes.isEmpty { return }
        changes.append((date, bundle))
        if changes.count > 256 { changes.removeFirst() }
    }
    func shouldNotify(_ event: CodexCompletion, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(event.completedAt) < 60,
              let current = changes.last?.1, !event.host.bundleIDs.contains(current),
              let previous = changes.last(where: { $0.0 <= event.completedAt })?.1,
              !event.host.bundleIDs.contains(previous) else { return false }
        return true
    }
}
