import Combine
import Foundation
import OSLog

@MainActor
public protocol GlobalSearchStoring: AnyObject {
    func searchAll(query: String) async throws -> GlobalSearchSnapshot
    func searchableClipboardText(id: Int64) async throws -> String?
    func searchablePromptText(id: Int64) async throws -> String?
}

public extension GlobalSearchStoring {
    func searchablePromptText(id: Int64) async throws -> String? { nil }
}

extension JotBloomStore: GlobalSearchStoring {}

public enum GlobalSearchPhase: Equatable, Sendable {
    case idle
    case debouncing
    case searching
    case results
    case empty
    case failure
}

public enum GlobalSearchFeedbackKind: Equatable, Sendable {
    case copied
    case error
}

public struct GlobalSearchFeedback: Equatable, Sendable {
    public let kind: GlobalSearchFeedbackKind
    public let message: String

    public init(kind: GlobalSearchFeedbackKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

@MainActor
public final class GlobalSearchViewModel: ObservableObject {
    @Published public var query = "" {
        didSet {
            guard !isApplyingReset, query != oldValue else { return }
            handleQueryChange()
        }
    }
    @Published public private(set) var phase: GlobalSearchPhase = .idle
    @Published public private(set) var snapshot: GlobalSearchSnapshot = .empty
    @Published public private(set) var scope: GlobalSearchScope = .all
    @Published public private(set) var selectedID: SearchResultID?
    @Published public private(set) var copiedResultID: SearchResultID?
    @Published public private(set) var feedback: GlobalSearchFeedback?
    @Published public private(set) var focusRequest = 0
    @Published public private(set) var lastSearchDurationMilliseconds: Double?

    public var onPasteboardWritten: ((Int) -> Void)?
    public var onRequestCollapse: (() -> Void)?
    public var onOpenInspiration: ((Int64) -> Void)?
    public var onOpenPrompt: ((Int64) -> Void)?

    public var selectedResult: GlobalSearchResult? {
        guard let selectedID else { return nil }
        return visibleResults.first { $0.id == selectedID }
    }

    public func count(for scope: GlobalSearchScope) -> Int {
        scope.source.map { snapshot.results(for: $0).count } ?? snapshot.allResults.count
    }

    public func displayedResults(for source: SearchResultSource) -> [GlobalSearchResult] {
        let results = snapshot.results(for: source)
        return scope == .all ? Array(results.prefix(2)) : (scope.source == source ? results : [])
    }

    public var visibleResults: [GlobalSearchResult] {
        SearchResultSource.allCases.flatMap { displayedResults(for: $0) }
    }

    public func selectScope(_ newScope: GlobalSearchScope) {
        guard scope != newScope else { return }
        // A pending copy must not collapse a newly selected category.
        actionRevision &+= 1
        actionTask?.cancel()
        feedbackTask?.cancel()
        copiedResultID = nil
        feedback = nil
        scope = newScope
        if !visibleResults.contains(where: { $0.id == selectedID }) {
            selectedID = visibleResults.first?.id
        }
    }

    public var queryRevision: UInt64 {
        searchRevision
    }

    private let store: GlobalSearchStoring
    private let pasteboardWriter: ClipboardWriting
    private let debounceNanoseconds: UInt64
    private let copiedFeedbackNanoseconds: UInt64
    private let logger = Logger(
        subsystem: "com.jotbloom.mengsheng",
        category: "global-search"
    )

    private var searchRevision: UInt64 = 0
    private var actionRevision: UInt64 = 0
    private var isApplyingReset = false
    private var searchTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    public init(
        store: GlobalSearchStoring,
        pasteboardWriter: ClipboardWriting,
        debounceNanoseconds: UInt64 = 150_000_000,
        copiedFeedbackNanoseconds: UInt64 = 800_000_000
    ) {
        self.store = store
        self.pasteboardWriter = pasteboardWriter
        self.debounceNanoseconds = debounceNanoseconds
        self.copiedFeedbackNanoseconds = copiedFeedbackNanoseconds
    }

    deinit {
        searchTask?.cancel()
        actionTask?.cancel()
        feedbackTask?.cancel()
    }

    public func activate() {
        requestInputFocus()
        guard SearchTextMatcher.normalizedQuery(query) != nil else { return }
        beginSearch(afterDebounce: false, preserveFeedback: false)
    }

    public func requestInputFocus() {
        focusRequest += 1
    }

    public func retry() {
        guard SearchTextMatcher.normalizedQuery(query) != nil else { return }
        beginSearch(afterDebounce: false, preserveFeedback: false)
    }

    public func refresh(preferredID: SearchResultID? = nil) {
        if let preferredID {
            selectedID = preferredID
        }
        guard SearchTextMatcher.normalizedQuery(query) != nil else { return }
        beginSearch(afterDebounce: false, preserveFeedback: true)
    }

    public func select(_ identifier: SearchResultID) {
        guard visibleResults.contains(where: { $0.id == identifier }) else {
            return
        }
        selectedID = identifier
    }

    public func moveSelection(by offset: Int) {
        let results = visibleResults
        guard !results.isEmpty else {
            selectedID = nil
            return
        }
        guard let selectedID,
              let currentIndex = results.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = offset < 0 ? results.last?.id : results.first?.id
            return
        }
        let destination = min(max(0, currentIndex + offset), results.count - 1)
        self.selectedID = results[destination].id
    }

    public func activateSelected() {
        guard let selectedResult else { return }
        activate(selectedResult.id)
    }

    public func activate(_ identifier: SearchResultID) {
        guard let result = visibleResults.first(where: { $0.id == identifier }) else {
            return
        }
        selectedID = result.id
        switch result.source {
        case .clipboard:
            copy(result: result, collapseAfterCopy: true)
        case .prompt:
            onOpenPrompt?(result.id.recordID)
        case .inspiration:
            onOpenInspiration?(result.id.recordID)
        }
    }

    @discardableResult
    public func copySelectedWithoutCollapsing() -> Bool {
        guard let selectedResult, selectedResult.source != .inspiration else {
            return false
        }
        copy(result: selectedResult, collapseAfterCopy: false)
        return true
    }

    public func reportInspirationOpenFailure(message: String) {
        feedbackTask?.cancel()
        copiedResultID = nil
        feedback = GlobalSearchFeedback(
            kind: .error,
            message: message
        )
        refresh()
    }

    public func resetForPanelDismissal() {
        searchRevision &+= 1
        actionRevision &+= 1
        searchTask?.cancel()
        searchTask = nil
        actionTask?.cancel()
        actionTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        isApplyingReset = true
        query = ""
        isApplyingReset = false
        phase = .idle
        snapshot = .empty
        scope = .all
        selectedID = nil
        copiedResultID = nil
        feedback = nil
        lastSearchDurationMilliseconds = nil
    }

    private func handleQueryChange() {
        actionRevision &+= 1
        actionTask?.cancel()
        actionTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        copiedResultID = nil
        feedback = nil
        guard SearchTextMatcher.normalizedQuery(query) != nil else {
            searchRevision &+= 1
            searchTask?.cancel()
            searchTask = nil
            phase = .idle
            snapshot = .empty
            selectedID = nil
            lastSearchDurationMilliseconds = nil
            return
        }
        beginSearch(afterDebounce: true, preserveFeedback: false)
    }

    private func beginSearch(
        afterDebounce: Bool,
        preserveFeedback: Bool
    ) {
        guard let normalizedQuery = SearchTextMatcher.normalizedQuery(query) else {
            return
        }
        searchRevision &+= 1
        let revision = searchRevision
        searchTask?.cancel()
        if !preserveFeedback {
            feedbackTask?.cancel()
            feedbackTask = nil
            copiedResultID = nil
            feedback = nil
        }
        phase = afterDebounce ? .debouncing : .searching
        let delay = afterDebounce ? debounceNanoseconds : 0

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled,
                      revision == searchRevision,
                      SearchTextMatcher.normalizedQuery(query) == normalizedQuery else {
                    return
                }
                phase = .searching
                let startedAt = ProcessInfo.processInfo.systemUptime
                let loaded = try await store.searchAll(query: normalizedQuery)
                let duration = (
                    ProcessInfo.processInfo.systemUptime - startedAt
                ) * 1_000
                guard !Task.isCancelled,
                      revision == searchRevision,
                      SearchTextMatcher.normalizedQuery(query) == normalizedQuery else {
                    return
                }
                apply(loaded)
                lastSearchDurationMilliseconds = duration
                phase = loaded.isEmpty ? .empty : .results
            } catch is CancellationError {
                return
            } catch {
                guard revision == searchRevision,
                      SearchTextMatcher.normalizedQuery(query) == normalizedQuery else {
                    return
                }
                logger.error(
                    "Global search failed: \(String(describing: error), privacy: .public)"
                )
                snapshot = .empty
                selectedID = nil
                phase = .failure
                lastSearchDurationMilliseconds = nil
            }
            if revision == searchRevision {
                searchTask = nil
            }
        }
    }

    private func apply(_ loaded: GlobalSearchSnapshot) {
        let oldResults = visibleResults
        let oldSelectedID = selectedID
        let oldIndex = oldSelectedID.flatMap { identifier in
            oldResults.firstIndex { $0.id == identifier }
        }
        snapshot = loaded
        let newResults = visibleResults
        if let oldSelectedID,
           newResults.contains(where: { $0.id == oldSelectedID }) {
            selectedID = oldSelectedID
        } else if let oldIndex, !newResults.isEmpty {
            selectedID = newResults[min(oldIndex, newResults.count - 1)].id
        } else {
            selectedID = newResults.first?.id
        }
    }

    private func copy(
        result: GlobalSearchResult,
        collapseAfterCopy: Bool
    ) {
        guard result.source != .inspiration else { return }
        actionRevision &+= 1
        let revision = actionRevision
        actionTask?.cancel()
        feedbackTask?.cancel()
        feedbackTask = nil
        copiedResultID = nil
        feedback = nil

        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = result.source == .prompt
                    ? try await store.searchablePromptText(id: result.id.recordID)
                    : try await store.searchableClipboardText(id: result.id.recordID)
                guard let text = loaded else {
                    guard revision == actionRevision else { return }
                    feedback = GlobalSearchFeedback(
                        kind: .error,
                        message: "这条内容已不存在，请重新搜索。"
                    )
                    beginSearch(afterDebounce: false, preserveFeedback: true)
                    actionTask = nil
                    return
                }
                try Task.checkCancellation()
                let changeCount = try pasteboardWriter.writeText(text)
                guard revision == actionRevision else { return }
                onPasteboardWritten?(changeCount)
                if collapseAfterCopy {
                    onRequestCollapse?()
                } else {
                    showCopiedFeedback(for: result.id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard revision == actionRevision else { return }
                logger.error(
                    "Search result copy failed: \(String(describing: error), privacy: .public)"
                )
                feedback = GlobalSearchFeedback(
                    kind: .error,
                    message: "无法复制这条内容。"
                )
            }
            if revision == actionRevision {
                actionTask = nil
            }
        }
    }

    private func showCopiedFeedback(for identifier: SearchResultID) {
        copiedResultID = identifier
        feedback = GlobalSearchFeedback(kind: .copied, message: "已复制")
        let delay = copiedFeedbackNanoseconds
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                guard copiedResultID == identifier else { return }
                copiedResultID = nil
                if feedback?.kind == .copied {
                    feedback = nil
                }
                feedbackTask = nil
            } catch {
                return
            }
        }
    }
}
