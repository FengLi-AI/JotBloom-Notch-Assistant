import Combine
import Foundation

@MainActor
public final class PromptLibraryViewModel: ObservableObject {
    @Published public private(set) var items: [Prompt] = []
    @Published public private(set) var selectedID: Int64?
    @Published public private(set) var focusRequest = 0
    @Published public private(set) var listRevealRequest = 0
    @Published public private(set) var isLoading = false
    @Published public private(set) var busy = false
    @Published public private(set) var hasMore = false
    @Published public var favoritesOnly = false { didSet { items = []; hasMore = false; refresh() } }
    public func toggleFavorite(_ prompt: Prompt) {
        run { [self] in
            try await store.setPromptFavorite(id: prompt.id, favorite: !prompt.isFavorite)
            feedback = prompt.isFavorite ? "已取消常用" : "已加入常用"; refresh()
        }
    }
    public func move(_ id: Int64, relativeTo target: Int64, after: Bool = false) {
        run { [self] in
            try await store.reorderLibrary(.prompts, id: id, relativeTo: target, after: after)
            refresh(); feedback = "顺序已保存"
        }
    }
    @Published public var feedback: String?
    @Published public private(set) var editingID: Int64?
    @Published public var editedTitle = ""
    @Published public private(set) var detailID: Int64?
    @Published public private(set) var savedCopyID: Int64?
    @Published public private(set) var editorBackName = "提示词库"
    private var returnFromEditor: (() -> Void)?
    @Published public var detailTitle = ""
    @Published public var detailContent = ""
    public var onEditorOpened: (() -> Void)?
    public var onEditorClosed: (() -> Void)?
    private var detailOriginal: Prompt?
    public var hasUnsavedDetail: Bool {
        guard let detailOriginal else { return false }
        return detailTitle != detailOriginal.title || detailContent != detailOriginal.content
    }
    @Published public private(set) var canUndo = false
    public var onPasteboardWritten: ((Int) -> Void)?
    public var onRequestCollapse: (() -> Void)?
    public var onChange: (() -> Void)?
    public var onPromptCreated: ((Int64) -> Void)?
    public var onInspirationCreated: ((Int64) -> Void)?
    private let store: JotBloomStore
    private let writer: ClipboardWriting
    private var loadRevision = 0
    private var actionRevision = 0
    private var actionTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    private var deleted: Prompt?
    public init(store: JotBloomStore, writer: ClipboardWriting) { self.store = store; self.writer = writer }
    deinit { loadTask?.cancel(); actionTask?.cancel(); undoTask?.cancel() }
    public func activate() { refresh(); if detailID == nil { requestFocus() } }
    public func requestFocus() { focusRequest += 1 }
    public func select(_ id: Int64) { selectedID = id }
    public func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(max(0, current + offset), items.count - 1)].id
        requestFocus()
    }
    public func refresh() {
        // Async titles must not unmount a row while its title is being edited.
        guard editingID == nil else { return }
        load(after: nil)
    }
    public func loadMore() { guard !isLoading, hasMore else { return }; load(after: items.last) }
    private func load(after cursor: Prompt?, preferredID: Int64? = nil) {
        loadRevision += 1; let revision = loadRevision
        loadTask?.cancel(); isLoading = true
        let visibleCount = max(50, items.count)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                var page = try await store.listPrompts(after: cursor, favoritesOnly: favoritesOnly)
                var lastPageCount = page.count
                if cursor == nil {
                    while (page.count < visibleCount || (preferredID != nil && !page.contains { $0.id == preferredID })), lastPageCount == 50, !Task.isCancelled {
                        let next = try await store.listPrompts(after: page.last, favoritesOnly: favoritesOnly)
                        lastPageCount = next.count; page += next
                    }
                }
                guard revision == loadRevision, !Task.isCancelled else { return }
                if cursor == nil { items = page } else { items += page.filter { row in !self.items.contains { $0.id == row.id } } }
                hasMore = lastPageCount == 50
                if let preferredID {
                    if items.contains(where: { $0.id == preferredID }) { selectedID = preferredID; listRevealRequest += 1 }
                    else { feedback = "新副本已不在库中，请查看全部或重新搜索。" }
                }
                if !items.contains(where: { $0.id == self.selectedID }) { selectedID = items.first?.id }
            } catch { if revision == loadRevision { feedback = "无法读取提示词，请重试。" } }
            if revision == loadRevision { isLoading = false; loadTask = nil }
        }
    }
    public func beginEditing(_ prompt: Prompt) {
        guard !busy, flushEdit() else { return }
        selectedID = prompt.id; editingID = prompt.id; editedTitle = prompt.title
    }
    public func openSelected() { if let selectedID { openEditor(selectedID) } }
    public func openEditor(_ id: Int64, returnName: String = "提示词库", onReturn: (() -> Void)? = nil) {
        guard !busy, flushEdit() else { return }
        let revision = actionRevision
        run { [self] in
            guard let prompt = try await store.prompt(id: id) else { throw PromptError.missing }
            guard revision == actionRevision else { return }
            selectedID = id; detailOriginal = prompt; detailID = id
            editorBackName = returnName; returnFromEditor = onReturn
            savedCopyID = nil
            detailTitle = prompt.title; detailContent = prompt.content
            onEditorOpened?()
        }
    }
    @discardableResult public func closeEditor(discard: Bool = false) -> Bool {
        guard !busy else { return false }
        if hasUnsavedDetail && !discard {
            feedback = "有未保存的修改，请先保存或点“放弃修改”。"
            return false
        }
        detailID = nil; detailOriginal = nil; detailTitle = ""; detailContent = ""
        editorBackName = "提示词库"; returnFromEditor = nil
        feedback = nil; refresh(); requestFocus(); onEditorClosed?()
        return true
    }
    @discardableResult public func returnFromDetail(discard: Bool = false) -> Bool {
        let destination = returnFromEditor
        guard closeEditor(discard: discard) else { return false }
        destination?()
        return true
    }
    public func saveDetail(asNew: Bool = false) {
        guard let id = detailID, !busy else { return }
        let title = detailTitle, content = detailContent, token = UUID().uuidString
        run { [self] in
            let savedID = try await store.savePromptEdits(id: id, title: title, content: content, asNew: asNew, token: token, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
            guard let saved = try await store.prompt(id: savedID) else { throw PromptError.missing }
            detailOriginal = saved; detailID = savedID; selectedID = savedID
            if asNew { savedCopyID = savedID }
            // Preserve any newer edits; the visible controls are disabled while saving.
            if detailTitle == title && detailContent == content { detailTitle = saved.title; detailContent = saved.content }
            feedback = asNew ? (favoritesOnly ? "已另存，原条目未修改；新副本可在“全部”中找到" : "已另存为新提示词，原条目未修改") : "已保存，当前提示词已更新"
            refresh(); onChange?()
        }
    }
    public func viewSavedCopy() {
        guard let id = savedCopyID, !busy, !hasUnsavedDetail else {
            if hasUnsavedDetail { feedback = "有未保存的修改，请先保存或放弃修改，再查看副本。" }
            return
        }
        guard closeEditor() else { return }
        savedCopyID = nil
        if favoritesOnly { favoritesOnly = false }
        load(after: nil, preferredID: id)
        feedback = "已切换到全部并定位新副本"
    }
    public func copyDetail() {
        guard detailID != nil, !busy else { return }
        do {
            let count = try writer.writeText(detailContent)
            onPasteboardWritten?(count); feedback = "已复制编辑区正文，面板保留；复制不会保存修改"
        } catch { feedback = "复制失败，内容仍保留。" }
    }
    public func cancelEdit() { editingID = nil; editedTitle = ""; refresh(); requestFocus() }
    @discardableResult public func flushEdit() -> Bool {
        if detailID != nil && (busy || hasUnsavedDetail) {
            feedback = busy ? "正在保存，请稍候。" : "有未保存的修改，请先保存或点“放弃修改”。"
            return false
        }
        guard let id = editingID else { return true }
        do {
            try store.renamePromptSynchronously(id: id, title: editedTitle)
            editingID = nil; editedTitle = ""; feedback = "标题已保存"; refresh(); onChange?()
            return true
        } catch { feedback = (error as? PromptError)?.localizedDescription ?? "标题保存失败，修改仍保留。"; return false }
    }
    public func saveClipboard(_ id: Int64, to target: SaveTarget) {
        run { [self] in
            let saved = try await store.saveClipboard(id: id, to: target, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
            refresh(); onChange?()
            feedback = (saved.created ? "已保存到" : "此前已保存到") + (target == .prompt ? "提示词" : "灵感")
            if saved.created, target == .prompt { onPromptCreated?(saved.id) }
            if saved.created, target == .inspiration { onInspirationCreated?(saved.id) }
        }
    }
    public func copySelected(collapse: Bool) { if let selectedID { copy(selectedID, collapse: collapse) } }
    public func copy(_ id: Int64, collapse: Bool) {
        guard flushEdit() else { return }
        selectedID = id
        let revision = actionRevision
        run { [self] in
            guard let prompt = try await store.prompt(id: id) else { throw PromptError.missing }
            guard revision == actionRevision, !Task.isCancelled else { return }
            let changeCount = try writer.writeText(prompt.content)
            onPasteboardWritten?(changeCount); feedback = "已复制"
            if collapse { onRequestCollapse?() }
        }
    }
    public func deleteSelected() { if let selectedID { delete(selectedID) } }
    public func delete(_ id: Int64) {
        guard flushEdit() else { return }
        run { [self] in
            let value = try await store.deletePrompt(id: id)
            deleted = value; canUndo = true; feedback = "已删除提示词，3 秒内可撤销"
            undoTask?.cancel()
            undoTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                self?.deleted = nil; self?.canUndo = false
                if self?.feedback == "已删除提示词，3 秒内可撤销" { self?.feedback = "提示词已删除，撤销时间已过" }
            }
            refresh(); onChange?()
        }
    }
    public func undoDeletion() {
        guard let deleted else { return }
        run { [self] in
            let associated = try await store.restorePrompt(deleted)
            self.deleted = nil; canUndo = false; undoTask?.cancel()
            feedback = associated ? "已撤销删除" : "已恢复提示词；原来源关联未恢复"
            refresh(); onChange?()
        }
    }
    public func panelDismissed() { actionRevision += 1 }
    public func prepareForMaintenance() async -> Bool {
        if let actionTask { await actionTask.value }
        return flushEdit()
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; feedback = nil
        actionTask = Task { [weak self] in
            do { try await action() }
            catch { self?.feedback = (error as? PromptError)?.localizedDescription ?? "操作失败，原内容保留，请重试。" }
            self?.busy = false; self?.actionTask = nil
        }
    }
}
