import Foundation

public protocol AssistantClock: Sendable { var now: Date { get } }
public struct SystemAssistantClock: AssistantClock { public init() {}; public var now: Date { Date() } }

/// One timer for the nearest pending reminder. Startup/wake aggregate missed reminders.
@MainActor
public final class ReminderScheduler {
    public var onDue: (([AssistantReminder], Bool) -> Void)?
    private let store: JotBloomStore
    private let clock: any AssistantClock
    private var timer: Timer?
    private var revision = 0
    private var announced: Set<String> = []
    private var stopped = true
    private var operations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public var hasPendingWrites: Bool { operations > 0 }
    public init(store: JotBloomStore, clock: any AssistantClock = SystemAssistantClock()) { self.store = store; self.clock = clock }
    public func start() async { stopped = false; await refresh(missed: true) }
    public func stop() { stopped = true; revision += 1; timer?.invalidate(); timer = nil }
    public func pauseAndDrain() async {
        stop()
        if operations > 0 { await withCheckedContinuation { waiters.append($0) } }
    }
    public func refresh(missed: Bool = false) async {
        guard !stopped else { return }
        operations += 1
        defer {
            operations -= 1
            if operations == 0 { let values = waiters; waiters.removeAll(); values.forEach { $0.resume() } }
        }
        revision += 1; let expected = revision
        timer?.invalidate(); timer = nil
        do {
            let now = Int64(clock.now.timeIntervalSince1970 * 1000)
            var due = try await store.deliverAssistantReminders(now: now, missed: missed)
            if missed {
                let ids = Set(due.map(\.id))
                due += try await store.assistantReminders().filter { $0.state != "pending" && !ids.contains($0.id) && !announced.contains($0.id) }
            }
            guard !stopped else { return }
            if !due.isEmpty { announced.formUnion(due.map(\.id)); onDue?(due, missed) }
            let next = try await store.assistantReminders().first { $0.state == "pending" }
            guard !stopped, expected == revision, let next else { return }
            let delay = max(0.05, Double(next.fireAt) / 1000 - clock.now.timeIntervalSince1970)
            let scheduled = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            timer = scheduled; RunLoop.main.add(scheduled, forMode: .common)
        } catch {
            guard !stopped, expected == revision else { return }
            // A transient storage failure must not silently disable all later reminders.
            let retry = Timer(timeInterval: 5, repeats: false) { [weak self] _ in Task { @MainActor in await self?.refresh(missed: missed) } }
            timer = retry; RunLoop.main.add(retry, forMode: .common)
        }
    }
}
