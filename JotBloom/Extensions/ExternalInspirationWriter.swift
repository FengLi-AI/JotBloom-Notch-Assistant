import Foundation
import JotBloomCore

/// Keeps extension writes in the same storage and maintenance lifecycle as the app.
@MainActor
final class ExternalInspirationWriter {
    private let store: JotBloomStore
    private let canWrite: () -> Bool
    private let didSave: (Int64) -> Void
    private var pending: [UUID: Task<Inspiration, Error>] = [:]
    var hasPendingSave: Bool { !pending.isEmpty }

    init(store: JotBloomStore, canWrite: @escaping () -> Bool, didSave: @escaping (Int64) -> Void) {
        self.store = store; self.canWrite = canWrite; self.didSave = didSave
    }

    func save(_ text: String) async throws {
        guard canWrite() else { throw SettingsError.maintenance }
        let key = UUID(), store = store
        let didSave = didSave
        let task = Task {
            let saved = try await store.saveExternalInspiration(text, timestampUTCms: Int64(Date().timeIntervalSince1970 * 1000))
            didSave(saved.id)
            return saved
        }
        pending[key] = task
        defer { pending[key] = nil }
        _ = try await task.value
    }

    func drain() async {
        for task in pending.values { _ = try? await task.value }
    }
}
