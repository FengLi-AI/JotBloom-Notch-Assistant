import Combine
import Foundation

@MainActor
public final class FileShelfViewModel: ObservableObject {
    @Published public private(set) var items: [FileReference] = []
    @Published public private(set) var busy = false
    @Published public private(set) var ready = false
    @Published public var feedback: String?
    @Published public var kind: ShelfFileKind? { didSet { if oldValue != kind { selection.removeAll() } } }
    @Published public var date: ClipboardDateFilter = .all { didSet { if oldValue != date { selection.removeAll() } } }
    @Published public var selection: Set<UUID> = []
    @Published public private(set) var problems: [UUID: String] = [:]
    @Published public var confirmingClear = false
    @Published public private(set) var canUndo = false
    public var canMutate: () -> Bool = { true }
    private let store: JotBloomStore
    private var undoItems: [FileReference]?
    public init(store: JotBloomStore) { self.store = store }
    public var visibleItems: [FileReference] {
        items.filter { (kind == nil || $0.kind == kind) && date.contains(Int64($0.addedAt.timeIntervalSince1970 * 1000)) }
    }
    public func waitForPendingOperations() async {
        while busy { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    public func resetFilters() { kind = nil; date = .all }
    public func selectAll() { selection = Set(visibleItems.map(\.id)) }
    public func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { items = try await store.loadFileShelf(); ready = true }
        catch { feedback = "中转站读取失败，请重试" }
    }
    public func refresh() async {
        guard ready, !busy, canMutate() else { return }
        busy = true; defer { busy = false }
        let originals = items
        let result = await Task.detached(priority: .userInitiated) {
            var values: [FileReference] = [], errors: [UUID: String] = [:]
            for item in originals {
                do { values.append(try item.resolved()) }
                catch { values.append(item); errors[item.id] = (error as? FileReferenceError)?.errorDescription ?? "无法访问原文件" }
            }
            return (values, errors)
        }.value
        problems = result.1
        if result.0 != originals { _ = await persist(result.0) }
    }
    /// Returns true only when every requested file was accepted and committed.
    public func add(_ urls: [URL], before target: UUID? = nil) async -> Bool {
        guard ready, !busy, canMutate(), !urls.isEmpty else { return false }
        busy = true; defer { busy = false }
        let results = await Task.detached(priority: .userInitiated) {
            urls.map { url -> Result<FileReference, FileReferenceError> in
                do { return .success(try FileReference.create(url: url)) }
                catch { return .failure(error as? FileReferenceError ?? .unavailable) }
            }
        }.value
        var inserted: [FileReference] = [], failed = 0, repeated = 0, reason: String?
        for result in results {
            switch result {
            case .failure(let error): failed += 1; reason = error.errorDescription
            case .success(var reference):
                if inserted.contains(where: { $0.identity == reference.identity }) { repeated += 1; continue }
                if let existing = items.first(where: { $0.identity == reference.identity }) {
                    reference.id = existing.id; reference.addedAt = existing.addedAt; repeated += 1
                }
                inserted.append(reference)
            }
        }
        guard !inserted.isEmpty else { feedback = reason ?? "请拖入本地文件"; return false }
        let existingIDs = Set(items.map(\.id))
        let newCount = inserted.filter { !existingIDs.contains($0.id) }.count
        let ids = Set(inserted.map(\.id))
        var next = items.filter { !ids.contains($0.id) }
        let index = target.flatMap { id in next.firstIndex { $0.id == id } } ?? (target == nil ? 0 : next.count)
        next.insert(contentsOf: inserted, at: index)
        guard await persist(next) else { return false }
        undoItems = nil; canUndo = false
        selection = ids; for id in ids { problems[id] = nil }
        feedback = "新增 \(newCount) 项 · 重复 \(repeated) 项 · 失败 \(failed) 项" + (failed > 0 ? "：\(reason ?? "无法访问")" : "")
        return failed == 0
    }
    public func move(_ ids: Set<UUID>, before target: UUID?) async {
        guard ready, !busy, canMutate() else { return }
        busy = true; defer { busy = false }
        let next = FileShelfOrder.moving(ids, before: target, items: items, visible: visibleItems)
        guard next != items else { return }
        if await persist(next) { undoItems = nil; canUndo = false }
    }
    public func removeSelection() async { await remove(selection.intersection(Set(visibleItems.map(\.id)))) }
    public func clearConfirmed() async {
        guard confirmingClear else { return }
        await remove(Set(items.map(\.id))); confirmingClear = false
    }
    private func remove(_ ids: Set<UUID>) async {
        guard ready, !busy, canMutate(), !ids.isEmpty else { return }
        busy = true; defer { busy = false }
        let previous = items
        if await persist(items.filter { !ids.contains($0.id) }) {
            undoItems = previous; canUndo = true; selection.subtract(ids)
            feedback = "已移除 \(previous.count - items.count) 项，原文件不变"
        }
    }
    public func undo() async {
        guard ready, !busy, canMutate(), let previous = undoItems else { return }
        busy = true; defer { busy = false }
        if await persist(previous) { undoItems = nil; canUndo = false; feedback = "已恢复中转站记录" }
    }
    public func replace(_ id: UUID, with url: URL) async {
        guard ready, !busy, canMutate(), let index = items.firstIndex(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false }
        do {
            var value = try await Task.detached { try FileReference.create(url: url) }.value
            guard !items.contains(where: { $0.id != id && $0.identity == value.identity }) else { feedback = "此文件已在中转站"; return }
            value.id = id; value.addedAt = items[index].addedAt
            var next = items; next[index] = value
            if await persist(next) { problems[id] = nil; undoItems = nil; canUndo = false; feedback = "已重新关联原文件" }
        } catch { feedback = (error as? FileReferenceError)?.errorDescription ?? "无法关联文件" }
    }
    /// Revalidate the entire selection at the native handoff; never export a partial batch.
    public func filesForHandoff(_ ids: Set<UUID>) -> [UUID: URL]? {
        guard ready, !busy, !confirmingClear, canMutate(), !ids.isEmpty else { return nil }
        var urls: [UUID: URL] = [:]
        for item in items where ids.contains(item.id) {
            do { urls[item.id] = try item.resolved().url; problems[item.id] = nil }
            catch { problems[item.id] = (error as? FileReferenceError)?.errorDescription ?? "无法访问原文件" }
        }
        guard urls.count == ids.count else { feedback = "选中项包含不可用文件，请重新选择或移除后再拖出"; return nil }
        return urls
    }
    private func persist(_ next: [FileReference]) async -> Bool {
        do { try await store.saveFileShelf(next); items = next; return true }
        catch { feedback = "未能保存中转站，原有记录和原文件保持不变"; return false }
    }
}
