import Combine
import Foundation
import OSLog

@MainActor
public protocol InspirationStoring: AnyObject {
    func loadDraft(kind: DraftKind) async throws -> Draft?
    func persistDraft(
        kind: DraftKind,
        content: String,
        updatedAtUTCms: Int64
    ) async throws
    func persistDraftSynchronously(
        kind: DraftKind,
        content: String,
        updatedAtUTCms: Int64
    ) throws
    func saveManualInspiration(
        _ parsed: ParsedInspiration,
        timestampUTCms: Int64
    ) async throws -> Inspiration
    func listRecentInspirations(limit: Int) async throws -> [Inspiration]
}

extension JotBloomStore: InspirationStoring {}

public struct InspirationFeedback: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case success
        case error
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

@MainActor
public final class InspirationInputViewModel: ObservableObject {
    @Published public var text = "" {
        didSet {
            handleTextChange()
        }
    }
    @Published public private(set) var recentInspirations: [Inspiration] = []
    @Published public private(set) var feedback: InspirationFeedback?
    @Published public private(set) var isReady = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var focusRequest = 0
    @Published public private(set) var canUndoClear = false
    private var clearedText: String?
    public func clearInput() {
        guard isReady, !isSaving, !text.isEmpty else { return }
        clearedText = text; text = ""; canUndoClear = true
        do { try flushDraftSynchronously(); feedback = .init(kind: .success, message: "已清空输入，可撤销") }
        catch { feedback = .init(kind: .error, message: "清空未能写入磁盘，可撤销恢复原文") }
    }
    public func undoClear() {
        guard text.isEmpty, let clearedText, !isSaving else { return }
        text = clearedText; self.clearedText = nil; canUndoClear = false
        feedback = .init(kind: .success, message: "已恢复输入")
    }

    public var canSave: Bool {
        isReady
            && !isSaving
            && InspirationTextParser.parse(text) != nil
    }

    public var hasPendingSave: Bool {
        saveTask != nil || isSaving
    }

    public var savePrompt: ((String, String, Int64) async throws -> CrossSourceSaveResult)?
    public var onPromptCreated: ((Int64) -> Void)?
    public var onInspirationCreated: ((Int64) -> Void)?
    public func showAIStatus(_ message: String) { feedbackTask?.cancel(); feedback = .init(kind: .error, message: message) }
    public var sendToChat: ((String) async throws -> Void)?
    public func discuss() {
        guard canSave, let sendToChat else { return }
        let content = text
        draftRevision &+= 1
        let revision = draftRevision
        draftTask?.cancel(); draftTask = nil; isSaving = true; feedback = nil
        saveTask = Task {
            do {
                try await sendToChat(content)
                clearSubmittedText(revision: revision)
            } catch { feedback = .init(kind: .error, message: ChatViewModel.message(error)) }
            isSaving = false; saveTask = nil
            if !text.isEmpty { scheduleDraftPersistence() }
        }
    }

    private let store: InspirationStoring
    private let debounceNanoseconds: UInt64
    private let nowUTCms: () -> Int64
    private let logger = Logger(
        subsystem: "com.jotbloom.mengsheng",
        category: "inspiration-input"
    )

    private var didStart = false
    private var isApplyingStoredState = false
    private var draftRevision: UInt64 = 0
    private var recentRevision: UInt64 = 0
    private var draftTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var recentTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    public init(
        store: InspirationStoring,
        debounceNanoseconds: UInt64 = 500_000_000,
        nowUTCms: @escaping () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        self.store = store
        self.debounceNanoseconds = debounceNanoseconds
        self.nowUTCms = nowUTCms
    }

    deinit {
        draftTask?.cancel()
        saveTask?.cancel()
        recentTask?.cancel()
        feedbackTask?.cancel()
    }

    public func start() {
        guard !didStart else { return }
        didStart = true

        Task { [weak self] in
            await self?.loadInitialState()
        }
    }

    public func requestInputFocus() {
        focusRequest += 1
    }

    public func refreshRecentInspirations() {
        guard isReady else { return }
        recentRevision &+= 1
        let revision = recentRevision
        let startedAt = ProcessInfo.processInfo.systemUptime
        recentTask?.cancel()
        recentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let recent = try await store.listRecentInspirations(
                    limit: JotBloomStore.recentInspirationLimit
                )
                guard revision == recentRevision else { return }
                recentInspirations = recent
            } catch {
                guard revision == recentRevision else { return }
                logPersistenceFailure(
                    error,
                    operation: "refresh_recent_inspirations",
                    startedAt: startedAt
                )
                feedback = InspirationFeedback(
                    kind: .error,
                    message: "无法刷新最近灵感，请稍后重试。"
                )
            }
            if revision == recentRevision {
                recentTask = nil
            }
        }
    }

    public func save() {
        guard canSave,
              let parsed = InspirationTextParser.parse(text) else {
            return
        }

        draftRevision &+= 1
        let submittedRevision = draftRevision
        draftTask?.cancel()
        draftTask = nil
        isSaving = true
        feedbackTask?.cancel()
        feedback = nil

        saveTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime

            do {
                let saved = try await store.saveManualInspiration(
                    parsed,
                    timestampUTCms: nowUTCms()
                )
                handleSaveSuccess(saved, submittedRevision: submittedRevision)
                onInspirationCreated?(saved.id)
            } catch {
                logPersistenceFailure(
                    error,
                    operation: "save_manual_inspiration",
                    startedAt: startedAt
                )
                if let error = error as? PromptError {
                    feedback = InspirationFeedback(kind: .error, message: error.localizedDescription)
                } else { handleSaveFailure() }
            }

            isSaving = false
            saveTask = nil
            if !text.isEmpty { scheduleDraftPersistence() }
        }
    }

    public func prepareForTermination() async throws {
        await waitForPendingSave()
        try flushDraftSynchronously()
    }

    public func saveToPrompt() {
        guard canSave, let savePrompt else { return }
        let content = text, token = UUID().uuidString
        draftRevision &+= 1
        let submittedRevision = draftRevision
        draftTask?.cancel(); draftTask = nil
        isSaving = true; feedbackTask?.cancel(); feedback = nil
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await savePrompt(content, token, nowUTCms())
                clearSubmittedText(revision: submittedRevision)
                feedback = InspirationFeedback(kind: .success, message: "已保存到提示词")
                if result.created { onPromptCreated?(result.id) }
            } catch {
                feedback = InspirationFeedback(kind: .error, message: (error as? PromptError)?.localizedDescription ?? "保存失败，输入仍保留，请重试。")
            }
            isSaving = false; saveTask = nil
            if !text.isEmpty { scheduleDraftPersistence() }
        }
    }

    public func waitForPendingSave() async {
        if let saveTask {
            await saveTask.value
        }
    }

    public func flushDraftSynchronously() throws {
        draftRevision &+= 1
        draftTask?.cancel()
        draftTask = nil

        guard isReady else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try store.persistDraftSynchronously(
                kind: .inspiration,
                content: text,
                updatedAtUTCms: nowUTCms()
            )
        } catch {
            logPersistenceFailure(
                error,
                operation: "flush_draft_for_termination",
                startedAt: startedAt
            )
            throw error
        }
    }

    private func loadInitialState() async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let draft = try await store.loadDraft(kind: .inspiration)
            let recent = try await store.listRecentInspirations(
                limit: JotBloomStore.recentInspirationLimit
            )

            isApplyingStoredState = true
            text = draft?.content ?? ""
            isApplyingStoredState = false
            recentInspirations = recent
            isReady = true
        } catch {
            logPersistenceFailure(
                error,
                operation: "load_initial_state",
                startedAt: startedAt
            )
            isApplyingStoredState = false
            feedback = InspirationFeedback(
                kind: .error,
                message: "无法读取本地数据，请重新启动萌生。"
            )
        }
    }

    private func handleTextChange() {
        guard isReady, !isApplyingStoredState else { return }
        if !text.isEmpty { canUndoClear = false; clearedText = nil }

        if feedback?.kind == .success {
            feedbackTask?.cancel()
            feedback = nil
        }

        scheduleDraftPersistence()
    }

    private func scheduleDraftPersistence() {
        draftRevision &+= 1
        // While a save consumes the persisted draft, newer edits stay in this model.
        // Persist them after the transaction, never let an old save erase a newer write.
        guard !isSaving else { return }
        let revision = draftRevision
        let snapshot = text

        draftTask?.cancel()
        draftTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                return
            }

            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                try await store.persistDraft(
                    kind: .inspiration,
                    content: snapshot,
                    updatedAtUTCms: nowUTCms()
                )
                guard revision == draftRevision else { return }
                draftTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard revision == draftRevision else { return }
                logPersistenceFailure(
                    error,
                    operation: "persist_draft",
                    startedAt: startedAt
                )
                draftTask = nil
                feedback = InspirationFeedback(
                    kind: .error,
                    message: "草稿未能保存，输入内容仍保留在窗口中。"
                )
            }
        }
    }

    private func clearSubmittedText(revision: UInt64) {
        if draftRevision == revision {
            isApplyingStoredState = true
            text = ""
            isApplyingStoredState = false
        }
    }

    private func handleSaveSuccess(_ inspiration: Inspiration, submittedRevision: UInt64) {
        recentRevision &+= 1
        recentTask?.cancel()
        recentTask = nil
        clearSubmittedText(revision: submittedRevision)

        recentInspirations.removeAll { $0.id == inspiration.id }
        recentInspirations.insert(inspiration, at: 0)
        if recentInspirations.count > JotBloomStore.recentInspirationLimit {
            recentInspirations.removeLast(
                recentInspirations.count - JotBloomStore.recentInspirationLimit
            )
        }

        feedback = InspirationFeedback(kind: .success, message: "已保存")
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                if self?.feedback?.kind == .success {
                    self?.feedback = nil
                }
            } catch {
                return
            }
        }
    }

    private func handleSaveFailure() {
        feedback = InspirationFeedback(
            kind: .error,
            message: "无法保存灵感，请检查磁盘空间后重试；输入内容仍保留。"
        )
        scheduleDraftPersistence()
    }

    private func logPersistenceFailure(
        _ error: Error,
        operation: String,
        startedAt: TimeInterval
    ) {
        let metadata = PersistenceDiagnostics.metadata(for: error)
        let sqliteCode = metadata.sqliteResultCode.map(String.init) ?? "none"
        let foundSchema = metadata.foundSchemaVersion.map(String.init) ?? "none"
        let durationMilliseconds = max(
            0,
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        )
        let message = "Persistence operation=\(operation) failed "
            + "kind=\(metadata.kind) "
            + "sqlite_code=\(sqliteCode) "
            + "found_schema=\(foundSchema) "
            + "supported_schema=\(DatabaseMigrator.currentVersion) "
            + "duration_ms=\(durationMilliseconds)"
        logger.error("\(message, privacy: .public)")
    }
}
