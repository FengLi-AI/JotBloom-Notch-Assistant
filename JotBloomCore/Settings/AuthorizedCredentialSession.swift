import Foundation

/// Process-local storage only. The owner serializes access and validates the
/// original security context on every reuse. Never encode or log this value.
public struct AuthorizedCredentialSession<Context> {
    private struct Entry {
        let secret: String
        let context: Context
    }
    private var entries: [ModelSlot: Entry] = [:]

    public init() {}

    public mutating func remember(_ secret: String, slot: ModelSlot, context: Context) {
        entries[slot] = Entry(secret: secret, context: context)
    }

    public mutating func read(_ slot: ModelSlot, validate: (Context) throws -> Void) throws -> String? {
        guard let entry = entries[slot] else { return nil }
        do {
            try validate(entry.context)
            return entry.secret
        } catch {
            entries.removeValue(forKey: slot)
            throw error
        }
    }

    public mutating func remove(_ slot: ModelSlot) { entries.removeValue(forKey: slot) }
}
