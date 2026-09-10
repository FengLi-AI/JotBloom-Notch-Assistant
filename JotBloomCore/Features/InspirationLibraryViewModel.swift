import Combine
import Foundation
import OSLog

@MainActor
public protocol InspirationLibraryStoring: AnyObject {
    func listInspirationsPage(after cursor: InspirationPageCursor?, limit: Int, category: InspirationCategory?) async throws -> InspirationPage
    func listInspirationsPage(
        after cursor: InspirationPageCursor?,
        limit: Int
    ) async throws -> InspirationPage
    func inspiration(id: Int64) async throws -> Inspiration
    func updateInspirationText(
        id: Int64,
        title: String,
        body: String,
        updatedAtUTCms: Int64
    ) async throws -> Inspiration
    func updateInspirationCategory(
        id: Int64,
        category: InspirationCategory,
        updatedAtUTCms: Int64
    ) async throws -> Inspiration
    func deleteInspiration(id: Int64) async throws -> Inspiration
    func restoreInspiration(_ inspiration: Inspiration) async throws -> Inspiration
}

extension JotBloomStore: InspirationLibraryStoring {}

extension InspirationLibraryStoring {
    public func listInspirationsPage(after cursor: InspirationPageCursor?, limit: Int, category: InspirationCategory?) async throws -> InspirationPage {
        guard category == nil else { throw PersistenceError.invalidSchema(object: "category_query_unavailable") }
        return try await listInspirationsPage(after: cursor, limit: limit)
    }
}

public enum InspirationLibraryScreen: Equatable, Sendable {
    case list
    case detail
}

public enum InspirationLibraryFeedbackKind: Equatable, Sendable {
    case saved
    case deleted
    case error
    case loadMoreError
}

public struct InspirationLibraryFeedback: Equatable, Sendable {
    public let kind: InspirationLibraryFeedbackKind
    public let message: String

    public init(kind: InspirationLibraryFeedbackKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

@MainActor
public final class InspirationLibraryViewModel: ObservableObject {
    public var onRequestEnrichment: ((Int64) -> Void)?
    public var enrichmentEnabled: (() -> Bool)?
    public func showAIStatus(_ message: String) { feedback = .init(kind: .error, message: message) }
    public func refreshAfterAI(id: Int64) async {
        aiRefreshRevision &+= 1
        if screen == .list { activate(); return }
        guard detailInspiration?.id == id, !isDetailLoading, !textIsDirty,
              !isSavingText, !isSavingCategory else { return }
        let refresh = aiRefreshRevision, route = detailRevision, text = textRevision
        let previous = savedDetail, category = detailCategory
        guard let record = try? await store.inspiration(id: id), !Task.isCancelled,
              refresh == aiRefreshRevision, route == detailRevision, text == textRevision,
              screen == .detail, detailInspiration?.id == id, previous == savedDetail,
              category == detailCategory, !textIsDirty, !isDetailLoading,
              !isSavingText, !isSavingCategory else { return }
        applyDetail(record)
    }
    public func retryEnrichment() {
        guard let id = detailInspiration?.id, enrichmentEnabled?() == true else { return }
        Task {
            guard await flushPendingChanges(showSavedFeedback: false) else { return }
            onRequestEnrichment?(id)
        }
    }
    @Published public private(set) var filterCategory: InspirationCategory?
    public func filter(_ category: InspirationCategory?) {
        guard screen == .list, category != filterCategory, !isReordering,
              deletionTask == nil, undoTask == nil else { return }
        filterCategory = category
        items = []; selectedID = nil; nextCursor = nil; isReady = false; feedback = nil
        reloadFirstPage(preserveSelection: false, preferredID: nil)
    }
    private func pageForCategory(after cursor: InspirationPageCursor?, limit: Int) async throws -> InspirationPage {
        try await store.listInspirationsPage(after: cursor, limit: limit, category: filterCategory)
    }
    @Published public private(set) var isReordering = false
    public func move(_ id: Int64, relativeTo target: Int64, after: Bool = false) {
        guard !isReordering, screen == .list, let actualStore = store as? JotBloomStore else { return }
        isReordering = true
        let loadedCount = items.count
        Task { [weak self] in
            guard let self else { return }
            do {
                try await actualStore.reorderLibrary(.inspirations, id: id, relativeTo: target, after: after, category: filterCategory)
                let snapshot = try await loadRefreshedPages(preferredID: id, minimumCount: loadedCount)
                applyRefreshSnapshot(snapshot, preferredID: id)
                feedback = .init(kind: .saved, message: "顺序已保存")
            } catch { feedback = .init(kind: .error, message: "排序未保存，请重试。") }
            isReordering = false
        }
    }
    @Published public private(set) var items: [Inspiration] = []
    @Published public private(set) var selectedID: Int64?
    @Published public private(set) var screen: InspirationLibraryScreen = .list
    @Published public private(set) var detailInspiration: Inspiration?
    @Published public var detailTitle = "" {
        didSet { handleTextChange() }
    }
    @Published public var detailBody = "" {
        didSet { handleTextChange() }
    }
    @Published public private(set) var detailCategory: InspirationCategory = .idea
    @Published public private(set) var feedback: InspirationLibraryFeedback?
    @Published public private(set) var isReady = false
    @Published public private(set) var isInitialLoading = false
    @Published public private(set) var isLoadingNextPage = false
    @Published public private(set) var isDetailLoading = false
    @Published public private(set) var isSavingText = false
    @Published public private(set) var isSavingCategory = false
    @Published public private(set) var textSaveFailed = false
    public var saveStatusMessage: String {
        if isDetailLoading { return "正在读取…" }
        if textSaveFailed { return "保存失败，修改仍保留" }
        if hasPendingSave { return "自动保存中…" }
        return "已保存"
    }
    @Published public private(set) var listFocusRequest = 0
    @Published public private(set) var detailFocusRequest = 0

    public var onRequestExpand: (() -> Void)?
    public var onDetailLoadFailure: ((Int64, String) -> Void)?

    public var selectedItem: Inspiration? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    public var canLoadMore: Bool {
        nextCursor != nil
    }

    public var canUndo: Bool {
        pendingDeletion != nil
    }

    public var hasPendingSave: Bool {
        textIsDirty
            || debounceTask != nil
            || textWriteTask != nil
            || categoryTask != nil
    }

    public var hasPendingOperation: Bool {
        initialLoadTask != nil
            || nextPageTask != nil
            || detailLoadTask != nil
            || deletionTask != nil
            || undoTask != nil
            || hasPendingSave
    }

    private let store: InspirationLibraryStoring
    private let pageLimit: Int
    private let debounceNanoseconds: UInt64
    private let undoNanoseconds: UInt64
    private let savedFeedbackNanoseconds: UInt64
    private let nowUTCms: () -> Int64
    private let logger = Logger(
        subsystem: "com.jotbloom.mengsheng",
        category: "inspiration-library"
    )

    private var didStart = false
    private var isApplyingDetail = false
    private var savedDetail: Inspiration?
    private var nextCursor: InspirationPageCursor?
    private var loadRevision: UInt64 = 0
    private var detailRevision: UInt64 = 0
    private var aiRefreshRevision: UInt64 = 0
    private var textRevision: UInt64 = 0
    private var writeToken: UInt64 = 0
    private var pendingDeletion: PendingInspirationDeletion?
    private var initialLoadTask: Task<Void, Never>?
    private var nextPageTask: Task<Void, Never>?
    private var detailLoadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var textWriteTask: Task<Bool, Never>?
    private var categoryTask: Task<Bool, Never>?
    private var deletionTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    private var undoExpiryTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    public init(
        store: InspirationLibraryStoring,
        pageLimit: Int = JotBloomStore.inspirationPageLimit,
        debounceNanoseconds: UInt64 = 500_000_000,
        undoNanoseconds: UInt64 = 3_000_000_000,
        savedFeedbackNanoseconds: UInt64 = 800_000_000,
        nowUTCms: @escaping () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) {
        self.store = store
        self.pageLimit = min(
            max(pageLimit, 1),
            JotBloomStore.maximumInspirationPageLimit
        )
        self.debounceNanoseconds = debounceNanoseconds
        self.undoNanoseconds = undoNanoseconds
        self.savedFeedbackNanoseconds = savedFeedbackNanoseconds
        self.nowUTCms = nowUTCms
    }

    deinit {
        initialLoadTask?.cancel()
        nextPageTask?.cancel()
        detailLoadTask?.cancel()
        debounceTask?.cancel()
        textWriteTask?.cancel()
        categoryTask?.cancel()
        deletionTask?.cancel()
        undoTask?.cancel()
        undoExpiryTask?.cancel()
        feedbackTask?.cancel()
    }

    public func start() {
        guard !didStart else { return }
        didStart = true
        reloadFirstPage(preserveSelection: false, preferredID: nil)
    }

    public func activate() {
        if screen == .detail, let identifier = detailInspiration?.id {
            refreshForDetailActivation(identifier: identifier)
        } else {
            reloadFirstPage(
                preserveSelection: true,
                preferredID: selectedID
            )
            requestListFocus()
        }
    }

    public func activateListPreservingDetail() {
        reloadFirstPage(
            preserveSelection: true,
            preferredID: selectedID
        )
        requestListFocus()
    }

    public func retryInitialLoad() {
        guard !isReady, initialLoadTask == nil else { return }
        feedback = nil
        reloadFirstPage(preserveSelection: false, preferredID: nil)
    }

    public func requestListFocus() {
        listFocusRequest += 1
    }

    public func select(_ identifier: Int64) {
        guard items.contains(where: { $0.id == identifier }) else {
            return
        }
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
        if offset > 0, destination >= items.count - 5 {
            loadNextPage()
        }
    }

    public func openSelected() {
        guard let selectedID else { return }
        open(identifier: selectedID)
    }

    @discardableResult
    public func open(identifier: Int64) -> Bool {
        guard screen == .list,
              let item = items.first(where: { $0.id == identifier }) else {
            return false
        }
        beginOpeningDetail(identifier: identifier, prefetched: item)
        return true
    }

    @discardableResult
    public func openFromSearch(identifier: Int64) -> Bool {
        guard screen == .list else { return false }
        beginOpeningDetail(identifier: identifier, prefetched: nil)
        return true
    }

    private func beginOpeningDetail(
        identifier: Int64,
        prefetched item: Inspiration?
    ) {
        detailRevision &+= 1
        let revision = detailRevision
        detailLoadTask?.cancel()
        if let item {
            applyDetail(item)
        } else {
            clearDetailForLoading()
        }
        screen = .detail
        isDetailLoading = true
        feedback = nil
        onRequestExpand?()

        detailLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await store.inspiration(id: identifier)
                guard revision == detailRevision, screen == .detail else { return }
                applyDetail(loaded)
                isDetailLoading = false
                detailFocusRequest += 1
            } catch {
                guard revision == detailRevision else { return }
                handleMissingOrFailedDetail(error, identifier: identifier)
            }
            if revision == detailRevision {
                detailLoadTask = nil
            }
        }
    }

    public func chooseCategory(_ category: InspirationCategory) {
        guard screen == .detail,
              let existingDetail = savedDetail,
              detailCategory != category,
              categoryTask == nil else {
            return
        }
        isApplyingDetail = true
        detailCategory = category
        isApplyingDetail = false
        isSavingCategory = true
        feedbackTask?.cancel()
        feedback = nil
        let identifier = existingDetail.id

        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            guard await flushText(flushAll: true, showSavedFeedback: false) else {
                revertCategoryToSavedValue()
                return false
            }
            do {
                let updated = try await store.updateInspirationCategory(
                    id: identifier,
                    category: category,
                    updatedAtUTCms: nowUTCms()
                )
                replaceItem(updated)
                if detailInspiration?.id == identifier {
                    savedDetail = updated
                    detailInspiration = updated
                    isApplyingDetail = true
                    detailCategory = updated.category
                    isApplyingDetail = false
                }
                return true
            } catch {
                logFailure(error, operation: "update_inspiration_category")
                revertCategoryToSavedValue()
                handleWriteFailure(error, fallbackMessage: "分类未能保存，已恢复原分类。")
                return false
            }
        }
        categoryTask = task
        Task { [weak self] in
            _ = await task.value
            guard let self, categoryTask != nil else { return }
            categoryTask = nil
            isSavingCategory = false
        }
    }

    public func loadNextPageIfNeeded(currentItemID: Int64) {
        guard let index = items.firstIndex(where: { $0.id == currentItemID }),
              index >= items.count - 5 else {
            return
        }
        loadNextPage()
    }

    public func loadNextPage() {
        guard isReady,
              !isInitialLoading,
              !isLoadingNextPage,
              nextPageTask == nil,
              let cursor = nextCursor else {
            return
        }
        isLoadingNextPage = true
        let revision = loadRevision
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await pageForCategory(
                    after: cursor,
                    limit: pageLimit
                )
                guard !Task.isCancelled, revision == loadRevision else { return }
                let existing = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
                nextCursor = page.nextCursor
                if feedback?.kind == .loadMoreError {
                    feedback = nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, revision == loadRevision else { return }
                logFailure(error, operation: "list_inspirations_next_page")
                feedback = InspirationLibraryFeedback(
                    kind: .loadMoreError,
                    message: "加载更多失败，点按重试"
                )
            }
            isLoadingNextPage = false
            nextPageTask = nil
        }
        nextPageTask = task
    }

    public func commandSave() {
        guard screen == .detail else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await flushPendingChanges(showSavedFeedback: true)
        }
    }

    public func flushAfterFocusLoss() {
        guard screen == .detail, textIsDirty else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await flushText(flushAll: true, showSavedFeedback: false)
        }
    }

    public func returnToList(
        completion: ((Bool) -> Void)? = nil
    ) {
        guard screen == .detail else {
            completion?(true)
            return
        }
        let identifier = detailInspiration?.id
        Task { [weak self] in
            guard let self else {
                completion?(false)
                return
            }
            guard await flushPendingChanges(showSavedFeedback: false) else {
                completion?(false)
                return
            }
            screen = .list
            reloadFirstPage(
                preserveSelection: true,
                preferredID: identifier
            )
            requestListFocus()
            completion?(true)
        }
    }

    public func flushBeforeTabChange(
        completion: @escaping (Bool) -> Void
    ) {
        guard screen == .detail else {
            completion(true)
            return
        }
        Task { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            completion(await flushPendingChanges(showSavedFeedback: false))
        }
    }

    public func resetForPanelDismissal() {
        guard screen == .detail else { return }
        detailRevision &+= 1
        detailLoadTask?.cancel()
        detailLoadTask = nil
        isDetailLoading = false
        Task { [weak self] in
            guard let self else { return }
            _ = await flushPendingChanges(showSavedFeedback: false)
        }
        screen = .list
    }

    public func deleteSelected() {
        guard let selectedID else { return }
        delete(identifier: selectedID)
    }

    public func delete(identifier: Int64) {
        guard deletionTask == nil,
              undoTask == nil,
              let originalIndex = items.firstIndex(where: { $0.id == identifier }) else {
            return
        }
        expireUndoWindow()
        let loadedCount = items.count
        deletionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let deleted = try await store.deleteInspiration(id: identifier)
                guard !Task.isCancelled else { return }
                let hadMoreItems = nextCursor != nil
                items.removeAll { $0.id == identifier }
                selectedID = selectionAfterDeletion(originalIndex: originalIndex)
                pendingDeletion = PendingInspirationDeletion(
                    inspiration: deleted,
                    loadedCount: loadedCount
                )
                feedback = InspirationLibraryFeedback(
                    kind: .deleted,
                    message: "已删除"
                )
                scheduleUndoExpiry(identifier: identifier)
                if hadMoreItems {
                    await refillOneItemAfterDeletion()
                }
            } catch {
                logFailure(error, operation: "delete_inspiration")
                handleWriteFailure(error, fallbackMessage: "无法删除，记录已保留。")
            }
            deletionTask = nil
        }
    }

    public func undoDeletion() {
        guard let pendingDeletion,
              deletionTask == nil,
              undoTask == nil else {
            return
        }
        self.pendingDeletion = nil
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        feedback = nil
        undoTask = Task { [weak self] in
            guard let self else { return }
            do {
                let restored = try await store.restoreInspiration(
                    pendingDeletion.inspiration
                )
                let snapshot = try await loadRefreshedPages(
                    preferredID: restored.id,
                    minimumCount: pendingDeletion.loadedCount
                )
                applyRefreshSnapshot(snapshot, preferredID: restored.id)
                requestListFocus()
            } catch {
                logFailure(error, operation: "restore_inspiration")
                feedback = InspirationLibraryFeedback(
                    kind: .error,
                    message: "无法恢复这条记录。"
                )
            }
            undoTask = nil
        }
    }

    public func prepareForTermination() async -> Bool {
        loadRevision &+= 1
        detailRevision &+= 1
        initialLoadTask?.cancel()
        nextPageTask?.cancel()
        detailLoadTask?.cancel()
        await initialLoadTask?.value
        await nextPageTask?.value
        await detailLoadTask?.value
        initialLoadTask = nil
        nextPageTask = nil
        detailLoadTask = nil
        isInitialLoading = false
        isLoadingNextPage = false
        isDetailLoading = false
        expireUndoWindow()
        feedbackTask?.cancel()
        feedbackTask = nil
        if let deletionTask {
            await deletionTask.value
        }
        if let undoTask {
            await undoTask.value
        }
        return await flushPendingChanges(showSavedFeedback: false)
    }

    private var textIsDirty: Bool {
        guard let savedDetail,
              detailInspiration?.id == savedDetail.id else {
            return false
        }
        return detailTitle != savedDetail.title || detailBody != savedDetail.body
    }

    private func handleTextChange() {
        guard screen == .detail, !isApplyingDetail, savedDetail != nil else { return }
        textSaveFailed = false
        textRevision &+= 1
        feedbackTask?.cancel()
        if feedback?.kind == .saved || feedback?.kind == .error {
            feedback = nil
        }
        scheduleDebouncedTextSave(revision: textRevision)
    }

    private func scheduleDebouncedTextSave(revision: UInt64) {
        debounceTask?.cancel()
        let delay = debounceNanoseconds
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                guard revision == textRevision else { return }
                debounceTask = nil
                _ = await flushText(
                    flushAll: false,
                    showSavedFeedback: false
                )
            } catch {
                return
            }
        }
    }

    private func flushPendingChanges(showSavedFeedback: Bool) async -> Bool {
        if let categoryTask {
            guard await categoryTask.value else { return false }
        }
        return await flushText(
            flushAll: true,
            showSavedFeedback: showSavedFeedback
        )
    }

    private func flushText(
        flushAll: Bool,
        showSavedFeedback: Bool
    ) async -> Bool {
        let pendingDebounce = debounceTask
        debounceTask = nil
        pendingDebounce?.cancel()
        await pendingDebounce?.value

        if let textWriteTask {
            guard await textWriteTask.value else { return false }
        }

        guard textIsDirty,
              let existingDetail = savedDetail else {
            if showSavedFeedback {
                showSavedFeedbackMessage()
            }
            return true
        }

        let identifier = existingDetail.id
        let titleSnapshot = detailTitle
        let bodySnapshot = detailBody
        let revision = textRevision
        writeToken &+= 1
        let token = writeToken
        isSavingText = true
        textSaveFailed = false

        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            do {
                let updated = try await store.updateInspirationText(
                    id: identifier,
                    title: titleSnapshot,
                    body: bodySnapshot,
                    updatedAtUTCms: nowUTCms()
                )
                savedDetail = updated
                textSaveFailed = false
                detailInspiration = updated
                replaceItem(updated)
                if revision == textRevision,
                   detailTitle == titleSnapshot,
                   detailBody == bodySnapshot,
                   showSavedFeedback {
                    showSavedFeedbackMessage()
                }
                return true
            } catch {
                logFailure(error, operation: "update_inspiration_text")
                textSaveFailed = true
                handleWriteFailure(
                    error,
                    fallbackMessage: "修改未能保存，请检查磁盘空间后重试。"
                )
                return false
            }
        }
        textWriteTask = task
        let succeeded = await task.value
        if token == writeToken {
            textWriteTask = nil
            isSavingText = false
        }
        guard succeeded else { return false }

        if textIsDirty {
            if flushAll {
                return await flushText(
                    flushAll: true,
                    showSavedFeedback: showSavedFeedback
                )
            }
            if debounceTask == nil {
                scheduleDebouncedTextSave(revision: textRevision)
            }
        }
        return true
    }

    private func reloadFirstPage(
        preserveSelection: Bool,
        preferredID: Int64?
    ) {
        loadRevision &+= 1
        let revision = loadRevision
        nextPageTask?.cancel()
        nextPageTask = nil
        isLoadingNextPage = false
        initialLoadTask?.cancel()
        isInitialLoading = true
        initialLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await pageForCategory(
                    after: nil,
                    limit: pageLimit
                )
                guard revision == loadRevision else { return }
                items = page.items
                nextCursor = page.nextCursor
                selectedID = selection(
                    in: page.items,
                    preserveSelection: preserveSelection,
                    preferredID: preferredID
                )
                isReady = true
                isInitialLoading = false
                if feedback?.kind == .loadMoreError {
                    feedback = nil
                }
            } catch {
                guard revision == loadRevision else { return }
                logFailure(error, operation: "list_inspirations_first_page")
                if !isReady {
                    items = []
                    selectedID = nil
                }
                isInitialLoading = false
                feedback = InspirationLibraryFeedback(
                    kind: .error,
                    message: "无法读取灵感库，请重新打开。"
                )
            }
            if revision == loadRevision {
                initialLoadTask = nil
            }
        }
    }

    private func refreshForDetailActivation(identifier: Int64) {
        detailRevision &+= 1
        let revision = detailRevision
        detailLoadTask?.cancel()
        isDetailLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            guard await flushPendingChanges(showSavedFeedback: false) else {
                if revision == detailRevision {
                    isDetailLoading = false
                    detailLoadTask = nil
                }
                return
            }
            guard !Task.isCancelled,
                  revision == detailRevision,
                  screen == .detail,
                  detailInspiration?.id == identifier else {
                return
            }
            do {
                async let pageRequest = store.listInspirationsPage(
                    after: nil,
                    limit: pageLimit
                )
                async let detailRequest = store.inspiration(id: identifier)
                let (page, detail) = try await (pageRequest, detailRequest)
                guard !Task.isCancelled,
                      revision == detailRevision,
                      screen == .detail,
                      detailInspiration?.id == identifier else {
                    return
                }
                items = page.items
                nextCursor = page.nextCursor
                selectedID = identifier
                applyDetail(detail)
                isDetailLoading = false
                detailFocusRequest += 1
            } catch is CancellationError {
                return
            } catch {
                guard revision == detailRevision else { return }
                handleMissingOrFailedDetail(error, identifier: identifier)
            }
            if revision == detailRevision {
                detailLoadTask = nil
            }
        }
        detailLoadTask = task
    }

    private func loadRefreshedPages(
        preferredID: Int64,
        minimumCount: Int
    ) async throws -> RefreshSnapshot {
        var page = try await pageForCategory(
            after: nil,
            limit: pageLimit
        )
        var collected = page.items
        var identifiers = Set(collected.map(\.id))
        var cursor = page.nextCursor

        while (!identifiers.contains(preferredID)
                || collected.count < minimumCount),
              let currentCursor = cursor {
            page = try await pageForCategory(
                after: currentCursor,
                limit: pageLimit
            )
            let additions = page.items.filter { identifiers.insert($0.id).inserted }
            collected.append(contentsOf: additions)
            cursor = page.nextCursor
        }
        return RefreshSnapshot(items: collected, nextCursor: cursor)
    }

    private func refillOneItemAfterDeletion() async {
        let cursor = items.last.map {
            InspirationPageCursor(
                updatedAtUTCms: $0.updatedAtUTCms,
                id: $0.id, sortOrder: $0.sortOrder
            )
        }
        do {
            let page = try await pageForCategory(
                after: cursor,
                limit: 1
            )
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            nextCursor = page.nextCursor
        } catch {
            logFailure(error, operation: "refill_after_inspiration_delete")
        }
    }

    private func applyRefreshSnapshot(
        _ snapshot: RefreshSnapshot,
        preferredID: Int64
    ) {
        items = snapshot.items
        nextCursor = snapshot.nextCursor
        selectedID = items.contains(where: { $0.id == preferredID })
            ? preferredID
            : items.first?.id
        isReady = true
    }

    private func applyDetail(_ inspiration: Inspiration) {
        isApplyingDetail = true
        textSaveFailed = false
        detailInspiration = inspiration
        savedDetail = inspiration
        detailTitle = inspiration.title
        detailBody = inspiration.body
        detailCategory = inspiration.category
        isApplyingDetail = false
        replaceItem(inspiration)
    }

    private func clearDetailForLoading() {
        isApplyingDetail = true
        detailInspiration = nil
        savedDetail = nil
        detailTitle = ""
        detailBody = ""
        detailCategory = .idea
        isApplyingDetail = false
    }

    private func replaceItem(_ inspiration: Inspiration) {
        guard let index = items.firstIndex(where: { $0.id == inspiration.id }) else {
            return
        }
        items[index] = inspiration
    }

    private func revertCategoryToSavedValue() {
        guard let savedDetail else { return }
        isApplyingDetail = true
        detailCategory = savedDetail.category
        isApplyingDetail = false
    }

    private func selection(
        in loaded: [Inspiration],
        preserveSelection: Bool,
        preferredID: Int64?
    ) -> Int64? {
        if let preferredID,
           loaded.contains(where: { $0.id == preferredID }) {
            return preferredID
        }
        if preserveSelection,
           let selectedID,
           loaded.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return loaded.first?.id
    }

    private func selectionAfterDeletion(originalIndex: Int) -> Int64? {
        guard !items.isEmpty else { return nil }
        return items[min(originalIndex, items.count - 1)].id
    }

    private func handleMissingOrFailedDetail(
        _ error: Error,
        identifier: Int64
    ) {
        logFailure(error, operation: "load_inspiration_detail")
        isDetailLoading = false
        screen = .list
        let message: String
        if case .inspirationNotFound = error as? PersistenceError {
            items.removeAll { $0.id == identifier }
            selectedID = items.first?.id
            message = "记录已不存在。"
        } else {
            message = "无法读取这条灵感，请重试。"
        }
        feedback = InspirationLibraryFeedback(kind: .error, message: message)
        requestListFocus()
        onDetailLoadFailure?(identifier, message)
    }

    private func handleWriteFailure(
        _ error: Error,
        fallbackMessage: String
    ) {
        if case let .inspirationNotFound(identifier) = error as? PersistenceError {
            items.removeAll { $0.id == identifier }
            selectedID = items.first?.id
            let wasShowingDetail = screen == .detail
            if wasShowingDetail {
                screen = .list
            }
            feedback = InspirationLibraryFeedback(
                kind: .error,
                message: "记录已不存在。"
            )
            if wasShowingDetail {
                onDetailLoadFailure?(identifier, "记录已不存在。")
            }
        } else {
            feedback = InspirationLibraryFeedback(
                kind: .error,
                message: (error as? PromptError)?.localizedDescription ?? fallbackMessage
            )
        }
    }

    private func scheduleUndoExpiry(identifier: Int64) {
        undoExpiryTask?.cancel()
        let delay = undoNanoseconds
        undoExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                guard pendingDeletion?.inspiration.id == identifier else { return }
                pendingDeletion = nil
                if feedback?.kind == .deleted {
                    feedback = nil
                }
                undoExpiryTask = nil
            } catch {
                return
            }
        }
    }

    private func expireUndoWindow() {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        pendingDeletion = nil
        if feedback?.kind == .deleted {
            feedback = nil
        }
    }

    private func showSavedFeedbackMessage() {
        feedbackTask?.cancel()
        feedback = InspirationLibraryFeedback(kind: .saved, message: "已保存")
        let delay = savedFeedbackNanoseconds
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                if feedback?.kind == .saved {
                    feedback = nil
                }
                feedbackTask = nil
            } catch {
                return
            }
        }
    }

    private func logFailure(_ error: Error, operation: String) {
        let metadata = PersistenceDiagnostics.metadata(for: error)
        let sqliteCode = metadata.sqliteResultCode.map(String.init) ?? "none"
        logger.error(
            "Inspiration operation=\(operation, privacy: .public) failed kind=\(metadata.kind, privacy: .public) sqlite_code=\(sqliteCode, privacy: .public)"
        )
    }
}

private struct PendingInspirationDeletion {
    let inspiration: Inspiration
    let loadedCount: Int
}

private struct RefreshSnapshot {
    let items: [Inspiration]
    let nextCursor: InspirationPageCursor?
}
