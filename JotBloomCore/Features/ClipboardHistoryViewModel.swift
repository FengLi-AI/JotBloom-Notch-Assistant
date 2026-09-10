import Combine
import Foundation
import OSLog

public enum ClipboardFeedbackKind: Equatable, Sendable {
    case copied
    case deleted
    case error
    case saved
}

public struct ClipboardFeedback: Equatable, Sendable {
    public let kind: ClipboardFeedbackKind
    public let message: String

    public init(kind: ClipboardFeedbackKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

@MainActor
public final class ClipboardHistoryViewModel: ObservableObject {
    @Published public var confirmingClear = false {
        didSet {
            if confirmingClear && !oldValue { clearSnapshot = items }
            if !confirmingClear { clearSnapshot = [] }
        }
    }
    private var clearSnapshot: [ClipboardItem] = []
    public var clearConfirmationMessage: String {
        "将清除本次确认范围内的 \(clearSnapshot.count) 条历史及其图片，不可撤销。之后新增或重新采集的记录保留。已另存的灵感、提示词、草稿及系统当前剪贴板不受影响；监听开关保持不变。"
    }
    @Published public private(set) var isClearing = false
    public var onClearHistory: (([ClipboardItem]) async throws -> Bool)?
    public func clearConfirmed() {
        guard confirmingClear, !isClearing, let onClearHistory else { return }
        isClearing = true
        let snapshot = clearSnapshot
        Task { [weak self] in
            guard let self else { return }
            do {
                let cleaned = try await onClearHistory(snapshot)
                confirmingClear = false
                feedback = .init(kind: .saved, message: cleaned ? "已清理确认范围内未变化的历史，监听设置不变" : "记录已清理，部分图片待清理；可在设置中重试")
            } catch { confirmingClear = false; feedback = .init(kind: .error, message: "清空失败，请重试。") }
            isClearing = false
        }
    }
    @Published public private(set) var items: [ClipboardItem] = []
    @Published public private(set) var thumbnailURLs: [Int64: URL] = [:]
    @Published public private(set) var unavailableImageIDs: Set<Int64> = []
    @Published public private(set) var selectedID: Int64?
    @Published public private(set) var copiedItemID: Int64?
    @Published public private(set) var feedback: ClipboardFeedback?
    @Published public private(set) var isReady = false
    @Published public private(set) var focusRequest = 0

    public var onPasteboardWritten: ((Int) -> Void)?
    public var onRequestCollapse: (() -> Void)?
    public func reportSaveFeedback(_ message: String) {
        feedbackTask?.cancel()
        feedback = ClipboardFeedback(kind: .saved, message: message)
    }

    public var canUndo: Bool {
        pendingDeletion != nil
    }

    public var hasPendingOperation: Bool {
        loadTask != nil || mutationTask != nil
    }

    public var selectedItem: ClipboardItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    public func isCopyAvailable(for item: ClipboardItem) -> Bool {
        item.contentType != .image || !unavailableImageIDs.contains(item.id)
    }

    private let service: ClipboardHistoryServicing
    private let pasteboardWriter: ClipboardWriting
    private let undoDurationNanoseconds: UInt64
    private let copiedFeedbackNanoseconds: UInt64
    private let nowUTCms: () -> Int64
    private let logger = Logger(
        subsystem: "com.jotbloom.mengsheng",
        category: "clipboard-history"
    )

    private var didStart = false
    private var loadRevision: UInt64 = 0
    private var mutationRevision: UInt64 = 0
    private var pendingDeletion: ClipboardItem?
    private var loadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var undoExpiryTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    public init(
        service: ClipboardHistoryServicing,
        pasteboardWriter: ClipboardWriting,
        undoDurationNanoseconds: UInt64 = 3_000_000_000,
        copiedFeedbackNanoseconds: UInt64 = 800_000_000,
        nowUTCms: @escaping () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        self.service = service
        self.pasteboardWriter = pasteboardWriter
        self.undoDurationNanoseconds = undoDurationNanoseconds
        self.copiedFeedbackNanoseconds = copiedFeedbackNanoseconds
        self.nowUTCms = nowUTCms
    }

    deinit {
        loadTask?.cancel()
        mutationTask?.cancel()
        undoExpiryTask?.cancel()
        feedbackTask?.cancel()
    }

    public func start() {
        guard !didStart else { return }
        didStart = true
        loadRevision &+= 1
        let revision = loadRevision

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await service.prepare(nowUTCms: nowUTCms())
                guard revision == loadRevision else { return }
                await apply(loaded, preserveSelection: false)
                isReady = true
            } catch {
                guard revision == loadRevision else { return }
                logFailure(error, operation: "prepare_clipboard_history")
                feedback = ClipboardFeedback(
                    kind: .error,
                    message: "无法读取剪贴板历史，请重新启动萌生。"
                )
            }
            loadTask = nil
        }
    }

    public func requestListFocus() {
        focusRequest += 1
    }

    public func select(_ identifier: Int64) {
        guard items.contains(where: { $0.id == identifier }) else { return }
        selectedID = identifier
    }

    public func moveSelection(by offset: Int) {
        guard !items.isEmpty else {
            selectedID = nil
            return
        }
        guard let selectedID,
              let index = items.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = offset < 0 ? items.last?.id : items.first?.id
            return
        }
        let destination = min(max(0, index + offset), items.count - 1)
        self.selectedID = items[destination].id
    }

    public func handleCaptureOutcome(_ outcome: ClipboardCaptureOutcome) {
        guard outcome != .skipped else { return }
        reloadItems(preserveSelection: true)
    }

    public func handleCaptureFailure(_ error: Error) {
        logFailure(error, operation: "capture_clipboard_item")
        feedback = ClipboardFeedback(
            kind: .error,
            message: "未能保存最新的剪贴板内容。"
        )
    }

    public func copySelected(collapseAfterCopy: Bool) {
        guard let selectedID else { return }
        copy(itemID: selectedID, collapseAfterCopy: collapseAfterCopy)
    }

    public func copy(itemID: Int64, collapseAfterCopy: Bool) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        guard isCopyAvailable(for: item) else {
            feedback = ClipboardFeedback(
                kind: .error,
                message: "图片文件已不可用，可删除这条记录。"
            )
            return
        }
        guard mutationTask == nil else { return }
        mutationRevision &+= 1
        let revision = mutationRevision

        mutationTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            do {
                let changeCount: Int
                switch item.contentType {
                case .text, .link:
                    guard let text = item.textContent else {
                        throw PersistenceError.invalidStoredValue(
                            column: "clipboard_items.text_content"
                        )
                    }
                    changeCount = try pasteboardWriter.writeText(text)
                case .image:
                    let data = try await service.imageData(for: item)
                    try Task.checkCancellation()
                    changeCount = try pasteboardWriter.writePNGData(data)
                }

                guard revision == mutationRevision else { return }
                onPasteboardWritten?(changeCount)
                if collapseAfterCopy {
                    feedbackTask?.cancel()
                    copiedItemID = nil
                    feedback = nil
                    onRequestCollapse?()
                } else {
                    copiedItemID = item.id
                    showCopiedFeedback(for: item.id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard revision == mutationRevision else { return }
                logFailure(error, operation: "copy_clipboard_item")
                feedback = ClipboardFeedback(
                    kind: .error,
                    message: item.contentType == .image
                        ? "图片文件已不可用，可删除这条记录。"
                        : "无法复制这条内容。"
                )
            }
            if revision == mutationRevision {
                mutationTask = nil
            }
        }
    }

    public func deleteSelected() {
        guard let selectedID else { return }
        delete(itemID: selectedID)
    }

    public func delete(itemID: Int64) {
        guard let item = items.first(where: { $0.id == itemID }),
              let originalIndex = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        guard mutationTask == nil else { return }
        mutationRevision &+= 1
        let revision = mutationRevision

        mutationTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await expirePendingDeletion()
            guard !Task.isCancelled else { return }
            do {
                guard let deleted = try await service.delete(id: item.id) else {
                    throw PersistenceError.invalidStoredValue(
                        column: "clipboard_items.id"
                    )
                }
                guard revision == mutationRevision else {
                    await service.finalizeDeletion(deleted)
                    return
                }
                items.removeAll { $0.id == deleted.id }
                thumbnailURLs.removeValue(forKey: deleted.id)
                unavailableImageIDs.remove(deleted.id)
                selectedID = selectionAfterDeletion(at: originalIndex)
                pendingDeletion = deleted
                feedback = ClipboardFeedback(kind: .deleted, message: "已删除")
                scheduleUndoExpiry(for: deleted)
            } catch {
                guard revision == mutationRevision else { return }
                logFailure(error, operation: "delete_clipboard_item")
                feedback = ClipboardFeedback(
                    kind: .error,
                    message: "无法删除，记录已保留。"
                )
            }
            if revision == mutationRevision {
                mutationTask = nil
            }
        }
    }

    public func undoDeletion() {
        guard let item = pendingDeletion else { return }
        guard mutationTask == nil else { return }
        mutationRevision &+= 1
        let revision = mutationRevision
        pendingDeletion = nil
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        feedback = nil

        mutationTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            do {
                let restored = try await service.restore(item)
                let loaded = try await service.listItems()
                guard revision == mutationRevision else { return }
                await apply(loaded, preserveSelection: false)
                selectedID = restored.id
            } catch {
                await service.finalizeDeletion(item)
                guard revision == mutationRevision else { return }
                logFailure(error, operation: "restore_clipboard_item")
                feedback = ClipboardFeedback(
                    kind: .error,
                    message: "无法恢复这条记录。"
                )
            }
            if revision == mutationRevision {
                mutationTask = nil
            }
        }
    }

    public func prepareForTermination() async {
        loadRevision &+= 1
        mutationRevision &+= 1
        let pendingLoadTask = loadTask
        let pendingMutationTask = mutationTask
        pendingLoadTask?.cancel()
        pendingMutationTask?.cancel()
        feedbackTask?.cancel()
        undoExpiryTask?.cancel()
        loadTask = nil
        mutationTask = nil
        feedbackTask = nil
        undoExpiryTask = nil
        await pendingLoadTask?.value
        await pendingMutationTask?.value
        if let pendingDeletion {
            self.pendingDeletion = nil
            await service.finalizeDeletion(pendingDeletion)
        }
    }

    public func refreshAfterMaintenance() {
        feedback = nil; copiedItemID = nil
        reloadItems(preserveSelection: true)
    }

    private func reloadItems(preserveSelection: Bool) {
        loadRevision &+= 1
        let revision = loadRevision
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await service.listItems()
                guard revision == loadRevision else { return }
                await apply(loaded, preserveSelection: preserveSelection)
            } catch {
                guard revision == loadRevision else { return }
                logFailure(error, operation: "reload_clipboard_history")
                feedback = ClipboardFeedback(
                    kind: .error,
                    message: "无法刷新剪贴板历史。"
                )
            }
            if revision == loadRevision {
                loadTask = nil
            }
        }
    }

    private func apply(
        _ loaded: [ClipboardItem],
        preserveSelection: Bool
    ) async {
        let previousSelection = selectedID
        let previousIndex = previousSelection.flatMap { identifier in
            items.firstIndex(where: { $0.id == identifier })
        }
        let loadedIdentifiers = Set(loaded.map(\.id))
        let adjacentSelection: Int64? = previousIndex.flatMap { index in
            let following = items.dropFirst(index + 1)
                .first(where: { loadedIdentifiers.contains($0.id) })?.id
            let preceding = items.prefix(index).reversed()
                .first(where: { loadedIdentifiers.contains($0.id) })?.id
            return following ?? preceding
        }
        items = loaded
        if preserveSelection,
           let previousSelection,
           loaded.contains(where: { $0.id == previousSelection }) {
            selectedID = previousSelection
        } else if preserveSelection,
                  let adjacentSelection {
            selectedID = adjacentSelection
        } else {
            selectedID = loaded.first?.id
        }

        var urls: [Int64: URL] = [:]
        var unavailable = Set<Int64>()
        for item in loaded where item.contentType == .image {
            if let url = await service.thumbnailURL(for: item) {
                urls[item.id] = url
            }
            if await !service.isImageAvailable(for: item) {
                unavailable.insert(item.id)
            }
        }
        thumbnailURLs = urls
        unavailableImageIDs = unavailable
    }

    private func selectionAfterDeletion(at originalIndex: Int) -> Int64? {
        guard !items.isEmpty else { return nil }
        return items[min(originalIndex, items.count - 1)].id
    }

    private func showCopiedFeedback(for identifier: Int64) {
        feedbackTask?.cancel()
        feedback = ClipboardFeedback(kind: .copied, message: "已复制")
        let duration = copiedFeedbackNanoseconds
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: duration)
                guard !Task.isCancelled else { return }
                guard self?.copiedItemID == identifier else { return }
                self?.copiedItemID = nil
                if self?.feedback?.kind == .copied {
                    self?.feedback = nil
                }
            } catch {
                return
            }
        }
    }

    private func scheduleUndoExpiry(for item: ClipboardItem) {
        undoExpiryTask?.cancel()
        let duration = undoDurationNanoseconds
        undoExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: duration)
                guard !Task.isCancelled, let self else { return }
                guard pendingDeletion?.id == item.id else { return }
                pendingDeletion = nil
                if feedback?.kind == .deleted {
                    feedback = nil
                }
                await service.finalizeDeletion(item)
                undoExpiryTask = nil
            } catch {
                return
            }
        }
    }

    private func expirePendingDeletion() async {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        guard let pendingDeletion else { return }
        self.pendingDeletion = nil
        await service.finalizeDeletion(pendingDeletion)
    }

    private func logFailure(_ error: Error, operation: String) {
        let metadata = PersistenceDiagnostics.metadata(for: error)
        let message = "Clipboard operation=\(operation) failed "
            + "kind=\(metadata.kind)"
        logger.error("\(message, privacy: .public)")
    }
}
