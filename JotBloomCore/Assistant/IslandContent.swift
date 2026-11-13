import Foundation

public enum IslandStage: Equatable { case hidden, glow, compact, expanded }
public enum IslandTone: Equatable { case blue, orange, green, red }
public enum IslandPriority: Int, Comparable {
    case received, completed, failed, reminder, blocker
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct IslandAction: Equatable, Identifiable {
    public let id: String
    public let title: String
    public init(_ id: String, _ title: String) { self.id = id; self.title = title }
}

public struct IslandDismissPolicy: Equatable {
    public let seconds: TimeInterval
    public let keepsPending: Bool
    public init(seconds: TimeInterval, keepsPending: Bool) {
        self.seconds = max(0, seconds); self.keepsPending = keepsPending
    }
    public static let received = Self(seconds: 2, keepsPending: false)
    public static let completed = Self(seconds: 6, keepsPending: false)
    public static let reminder = Self(seconds: 8, keepsPending: true)
    public static let blocker = Self(seconds: 10, keepsPending: true)
    public static let failed = Self(seconds: 8, keepsPending: true)
}

/// Presentation only. An action is an intent for the host, never permission to run a tool.
public struct IslandContent: Equatable, Identifiable {
    public let id: UUID
    public let taskID: String?
    public let priority: IslandPriority
    public let tone: IslandTone
    public let compactText: String
    public let title: String
    public let body: String?
    public let actions: [IslandAction]
    public let policy: IslandDismissPolicy

    public init(id: UUID = UUID(), taskID: String? = nil, priority: IslandPriority,
                tone: IslandTone, compactText: String, title: String, body: String? = nil,
                actions: [IslandAction] = [], policy: IslandDismissPolicy) {
        self.id = id; self.taskID = taskID; self.priority = priority; self.tone = tone
        self.compactText = compactText; self.title = title; self.body = body
        self.actions = Array(actions.prefix(2)); self.policy = policy
    }

    public var compactLabel: String {
        compactText.count > 22 ? String(compactText.prefix(21)) + "…" : compactText
    }
}

public struct IslandBatch: Equatable {
    public var events: [IslandContent]
    public let startedAt: TimeInterval
    public var priority: IslandPriority { events[0].priority }
    public var content: IslandContent {
        guard events.count > 1 else { return events[0] }
        let first = events[0], label = "\(events.count) 件事有更新"
        return IslandContent(id: first.id, priority: first.priority, tone: first.tone,
                             compactText: label, title: label,
                             body: events.prefix(3).map(\.title).joined(separator: "\n"),
                             actions: [.init("showUpdates", "看一下")],
                             policy: .init(seconds: events.map(\.policy.seconds).max() ?? 8,
                                           keepsPending: events.contains { $0.policy.keepsPending }))
    }
}

/// Deterministic event queue; time is supplied by the host, so suspension and merging are testable.
public struct IslandEventQueue {
    public private(set) var current: IslandBatch?
    public private(set) var waiting: [IslandBatch] = []
    public private(set) var pending: Set<UUID> = []
    public var hasPending: Bool { !pending.isEmpty }
    public init() {}

    public mutating func enqueue(_ content: IslandContent, at time: TimeInterval, presenting: Bool) {
        guard current?.events.contains(where: { $0.id == content.id }) != true,
              !waiting.contains(where: { $0.events.contains { $0.id == content.id } }) else { return }
        if content.policy.keepsPending { pending.insert(content.id) }
        if presenting, var active = current {
            if active.priority == content.priority, time - active.startedAt <= 10 {
                active.events.append(content); current = active; return
            }
            if content.priority > active.priority {
                waiting.insert(active, at: 0)
                current = IslandBatch(events: [content], startedAt: time)
                return
            }
        } else if presenting {
            current = IslandBatch(events: [content], startedAt: time); return
        }
        if let index = waiting.lastIndex(where: { $0.priority == content.priority && time - $0.startedAt <= 10 }) {
            waiting[index].events.append(content)
        } else {
            waiting.append(IslandBatch(events: [content], startedAt: time))
        }
    }

    public mutating func suspend() {
        if let current { waiting.insert(current, at: 0) }
        current = nil
    }

    /// On returning from a suppressed environment, combine all held events of each priority.
    public mutating func resume() {
        var merged: [IslandBatch] = []
        for batch in waiting {
            if let index = merged.firstIndex(where: { $0.priority == batch.priority }) {
                merged[index].events.append(contentsOf: batch.events)
            } else { merged.append(batch) }
        }
        waiting = merged
        advance()
    }

    public mutating func dismissCurrent(resolved: Bool = false) {
        if resolved, let current { pending.subtract(current.events.map(\.id)) }
        current = nil
    }

    public mutating func resolve(_ ids: Set<UUID>) {
        pending.subtract(ids)
        if var active = current {
            active.events.removeAll { ids.contains($0.id) }
            current = active.events.isEmpty ? nil : active
        }
        waiting = waiting.compactMap { batch in
            var remaining = batch; remaining.events.removeAll { ids.contains($0.id) }
            return remaining.events.isEmpty ? nil : remaining
        }
    }

    public mutating func advance() {
        guard current == nil, let priority = waiting.map(\.priority).max(),
              let index = waiting.firstIndex(where: { $0.priority == priority }) else { return }
        current = waiting.remove(at: index)
    }
}
