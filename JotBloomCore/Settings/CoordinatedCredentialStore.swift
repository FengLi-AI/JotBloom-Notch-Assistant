import Foundation

/// Daily reads never prompt. Only explicit recovery can share an authorization.
/// The underlying store remains responsible for validating cached permissions.
public actor CoordinatedCredentialStore: CredentialStoring {
    private struct Pending {
        let id: UUID
        let task: Task<String?, Error>
        let revision: Int
    }
    private let base: any CredentialStoring
    private var pending: [ModelSlot: Pending] = [:]
    private var revisions: [ModelSlot: Int] = [:]
    public init(base: any CredentialStoring) { self.base = base }

    public func read(_ slot: ModelSlot) async throws -> String? {
        try await readWithoutInteraction(slot)
    }

    public func authorize(_ slot: ModelSlot) async throws -> String? {
        try Task.checkCancellation()
        let operation: Pending
        if let existing = pending[slot] { operation = existing }
        else {
            let task = Task { [base] () throws -> String? in
                do { return try await base.readWithoutInteraction(slot) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    return try await base.authorize(slot)
                }
            }
            operation = Pending(id: UUID(), task: task, revision: revisions[slot, default: 0])
            pending[slot] = operation
        }
        defer { if pending[slot]?.id == operation.id { pending.removeValue(forKey: slot) } }
        let result = try await operation.task.value
        try Task.checkCancellation()
        guard revisions[slot, default: 0] == operation.revision else { throw SettingsError.credentialUnavailable }
        return result
    }
    public func readWithoutInteraction(_ slot: ModelSlot) async throws -> String? {
        try Task.checkCancellation()
        let revision = revisions[slot, default: 0]
        let result = try await base.readWithoutInteraction(slot)
        try Task.checkCancellation()
        guard revision == revisions[slot, default: 0] else { throw SettingsError.credentialUnavailable }
        return result
    }
    public func write(_ secret: String, slot: ModelSlot) async throws {
        invalidate(slot); try await base.write(secret, slot: slot)
    }
    public func remove(_ slot: ModelSlot) async throws {
        invalidate(slot); try await base.remove(slot)
    }
    private func invalidate(_ slot: ModelSlot) {
        revisions[slot, default: 0] += 1
        pending.removeValue(forKey: slot)?.task.cancel()
    }
}
