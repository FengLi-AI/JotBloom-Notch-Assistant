import AppKit
import JotBloomCore
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct FileShelfGrid: NSViewRepresentable {
    @ObservedObject var model: FileShelfViewModel
    let drag: FileShelfDragController
    var metrics: LibraryLayoutMetrics
    @Environment(\.bloomLibraryResize) var resize
    var batchSelection: Bool
    var onChooseReplacement: (UUID) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ShelfScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let grid = ShelfCollectionView()
        grid.wantsLayer = true
        grid.backgroundColors = [.clear]; grid.isSelectable = true; grid.allowsMultipleSelection = true
        grid.collectionViewLayout = ShelfFlowLayout()
        grid.register(ShelfCollectionItem.self, forItemWithIdentifier: .init("file"))
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        grid.dataSource = context.coordinator; grid.delegate = context.coordinator
        grid.owner = context.coordinator
        grid.setAccessibilityLabel("中转站文件网格")
        grid.frame = NSRect(x: 0, y: 0, width: 600, height: 160)
        grid.autoresizingMask = [.width]
        scroll.documentView = grid
        context.coordinator.grid = grid
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let owner = context.coordinator; owner.parent = self
        guard let grid = owner.grid else { return }
        guard !owner.committingReorder else { return }
        (grid.collectionViewLayout as? ShelfFlowLayout)?.reducesMotion = drag.reducesMotion()
        (grid.collectionViewLayout as? ShelfFlowLayout)?.setResize(resize)
        let next = model.visibleItems
        let needsReload = owner.items != next || owner.problems != model.problems
        owner.items = next; owner.problems = model.problems
        if needsReload { grid.reloadData(); grid.needsLayout = true }
        let selected = Set(next.enumerated().compactMap { model.selection.contains($0.element.id) ? IndexPath(item: $0.offset, section: 0) : nil })
        if grid.selectionIndexPaths != selected { grid.selectionIndexPaths = selected }
        grid.resizeGrid()

    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: FileShelfGrid
        weak var grid: ShelfCollectionView?
        var items: [FileReference] = []
        var problems: [UUID: String] = [:]
        var handoff: [UUID: URL] = [:]
        var committingReorder = false
        init(_ parent: FileShelfGrid) { self.parent = parent }
        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: .init("file"), for: indexPath) as! ShelfCollectionItem
            let record = items[indexPath.item]
            cell.configure(record, problem: problems[record.id])
            return cell
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
        func syncSelection() {
            guard let grid else { return }
            let ids = Set(grid.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].id : nil })
            if parent.model.selection != ids { parent.model.selection = ids }
        }
        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            let ids = Set(indexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].id : nil })
            guard let urls = parent.model.filesForHandoff(ids) else { return false }
            handoff = urls; return true
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard items.indices.contains(indexPath.item), let url = handoff[items[indexPath.item].id] else { return nil }
            return url as NSURL
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            grid?.dragStartedDuringMouseDown = true
            parent.drag.startInternal(Set(indexPaths.map { items[$0.item].id }))
            let excluded = Set(indexPaths.map(\.item))
            (collectionView.collectionViewLayout as? ShelfFlowLayout)?.setDrag(excluding: excluded, insertion: excluded.min() ?? 0)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {

            if !committingReorder { clearGap() }
            handoff = [:]; parent.drag.endInternal(operation)
        }
        func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath index: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation operation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard !parent.model.busy, !parent.model.confirmingClear else { return [] }

            let internalDrag = (info.draggingSource as? NSCollectionView) === collectionView && !parent.drag.internalIDs.isEmpty
            if !internalDrag {
                guard info.draggingSourceOperationMask.contains(.copy), parent.drag.enter(info) else { return [] }
            }
            operation.pointee = .before
            let point = collectionView.convert(info.draggingLocation, from: nil)
            guard let layout = collectionView.collectionViewLayout as? ShelfFlowLayout else { return [] }
            let excluded = internalDrag ? Set(items.indices.filter { parent.drag.internalIDs.contains(items[$0].id) }) : []
            let position = layout.insertionIndex(at: point, excluding: excluded)
            layout.setDrag(excluding: excluded, insertion: position)
            index.pointee = IndexPath(item: layout.originalIndex(forInsertion: position), section: 0) as NSIndexPath
            return internalDrag ? .move : .copy
        }
        func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {

            let target = items.indices.contains(indexPath.item) ? items[indexPath.item].id : nil
            if (info.draggingSource as? NSCollectionView) === collectionView && !parent.drag.internalIDs.isEmpty {
                parent.drag.internalDrop = true
                let ids = parent.drag.internalIDs
                committingReorder = true
                Task {
                    await parent.model.move(ids, before: target)
                    // Keep the preview until persistence finishes; otherwise the old
                    // order flashes back between mouse-up and the model update.
                    items = parent.model.visibleItems
                    clearGap(animated: false)
                    grid?.reloadData()
                    grid?.selectionIndexPaths = Set(items.enumerated().compactMap { parent.model.selection.contains($0.element.id) ? IndexPath(item: $0.offset, section: 0) : nil })
                    committingReorder = false
                }
                return true
            }
            clearGap()
            return parent.drag.accept(info, before: target, append: target == nil, fromNotch: false)
        }
        func clearGap(animated: Bool = true) {
            (grid?.collectionViewLayout as? ShelfFlowLayout)?.setDrag(excluding: [], insertion: nil, animated: animated)
        }
        func openSelection(reveal: Bool = false) {
            guard let urls = parent.model.filesForHandoff(parent.model.selection) else { return }
            if reveal { NSWorkspace.shared.activateFileViewerSelecting(Array(urls.values)) }
            else { for url in urls.values { NSWorkspace.shared.open(url) } }
        }
        func moveSelection(_ direction: Int) {
            let selected = items.indices.filter { parent.model.selection.contains(items[$0].id) }
            guard let first = selected.first, let last = selected.last else { return }
            let target: UUID?
            if direction < 0 { guard first > 0 else { return }; target = items[first - 1].id }
            else { guard last + 1 < items.count else { return }; target = last + 2 < items.count ? items[last + 2].id : nil }
            let ids = parent.model.selection
            Task { await parent.model.move(ids, before: target) }
        }
        @objc func openFiles() { openSelection() }
        @objc func revealFiles() { openSelection(reveal: true) }
        @objc func removeFiles() { Task { await parent.model.removeSelection() } }
        @objc func earlier() { moveSelection(-1) }
        @objc func later() { moveSelection(1) }
        @objc func replaceFile() { if let id = parent.model.selection.first { parent.onChooseReplacement(id) } }
        func menu() -> NSMenu {
            let menu = NSMenu()
            for (title, action) in [("打开原文件", #selector(openFiles)), ("在 Finder 中显示", #selector(revealFiles)), ("向前移动", #selector(earlier)), ("向后移动", #selector(later)), ("重新选择原文件…", #selector(replaceFile)), ("从中转站移除", #selector(removeFiles))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
                if action == #selector(replaceFile) { item.isEnabled = parent.model.selection.count == 1 }
                menu.addItem(item)
            }
            menu.autoenablesItems = false
            return menu
        }
    }
}

final class ShelfScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let grid = documentView as? ShelfCollectionView else { return }
        let size = NSSize(width: contentSize.width, height: max(contentSize.height, grid.collectionViewLayout?.collectionViewContentSize.height ?? 0))
        if grid.frame.size != size { grid.setFrameSize(size) }
        grid.resizeGrid()
    }
}

final class ShelfCollectionView: NSCollectionView {
    weak var owner: FileShelfGrid.Coordinator?
    var dragStartedDuringMouseDown = false
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); resizeGrid() }
    func resizeGrid() {
        guard let layout = collectionViewLayout as? ShelfFlowLayout else { return }
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        guard width > 0 else { return }
        guard let metrics = owner?.parent.metrics else { return }
        let columns = metrics.columns
        let size = NSSize(width: floor((width - CGFloat(columns - 1) * 8) / CGFloat(columns)), height: metrics.cardHeight)
        layout.setSizing(size, columns: columns)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in
            guard let self, self.owner?.parent.drag.active != true else { return }
            self.window?.makeFirstResponder(self)
        } }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if owner?.committingReorder != true { owner?.clearGap() }
        super.draggingExited(sender)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        if owner?.committingReorder != true { owner?.clearGap() }
        owner?.parent.drag.cancel(); super.draggingEnded(sender)
    }
    override func mouseDown(with event: NSEvent) {
        dragStartedDuringMouseDown = false
        let prior = selectionIndexPaths
        let index = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        // AppKit may return either before or after its drag session ends.
        // A completed/cancelled drag must never also toggle a batch selection.
        guard !dragStartedDuringMouseDown else { return }
        if owner?.parent.batchSelection == true, owner?.parent.drag.internalIDs.isEmpty == true,
           event.clickCount == 1, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), let index {
            selectionIndexPaths = prior.symmetricDifference([index])
            owner?.syncSelection()
        }
        if event.clickCount == 2 { owner?.openSelection() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let index = indexPathForItem(at: location) else { return nil }
        if !selectionIndexPaths.contains(index) { selectionIndexPaths = [index]; owner?.syncSelection() }
        return owner?.menu()
    }
    override func keyDown(with event: NSEvent) {
        guard owner?.parent.model.busy != true, owner?.parent.model.confirmingClear != true else { return }
        if event.keyCode == 36 { owner?.openSelection(); return }
        if event.keyCode == 51 || event.keyCode == 117 { owner?.removeFiles(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" { selectAll(nil); owner?.syncSelection(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { if let model = owner?.parent.model { Task { await model.undo() } }; return }
        if event.modifierFlags.contains(.option), event.keyCode == 123 || event.keyCode == 124 { owner?.moveSelection(event.keyCode == 123 ? -1 : 1); return }
        super.keyDown(with: event)
    }
}

/// Layout removes the lifted items before inserting ONE destination slot.
/// Dragging outside restores the full, committed order with no holes.
final class ShelfFlowLayout: NSCollectionViewLayout {
    private(set) var insertion: Int?
    private(set) var excluded: Set<Int> = []
    var reducesMotion = false
    private(set) var itemSize = NSSize(width: 110, height: 92)
    private var fixedColumns: Int?
    private var startingFrames: [Int: NSRect] = [:]
    private var progress: CGFloat = 1
    private var motion: Timer?
    private var resize: LibraryLayoutTransition?
    private var resizeStart: [Int: NSRect] = [:]
    private var resizeStartColumns = 1
    private let gapView = ShelfInsertionIndicator(frame: .zero)
    private var count: Int { collectionView?.numberOfItems(inSection: 0) ?? 0 }
    private var remaining: [Int] { (0..<count).filter { !excluded.contains($0) } }
    private var columns: Int {
        fixedColumns ?? max(1, Int(((collectionView?.enclosingScrollView?.contentSize.width ?? 616) + 8) / (itemSize.width + 8)))
    }
    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        if gapView.superview !== collectionView { collectionView.addSubview(gapView) }
        gapView.isHidden = insertion == nil
        if let insertion { gapView.frame = slotFrame(insertion); gapView.needsDisplay = true }
    }
    func setSizing(_ size: NSSize, columns nextColumns: Int) {
        guard size != itemSize || fixedColumns != nextColumns else { return }
        itemSize = size; fixedColumns = nextColumns
        invalidateLayout()
    }
    func setResize(_ next: LibraryLayoutTransition?) {
        guard next != resize else { return }
        if let next {
            if resize == nil || next.progress < (resize?.progress ?? 0) || next.progress == 0 {
                resizeStart = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, frame(for: $0)) })
                resizeStartColumns = columns
                motion?.invalidate(); motion = nil; progress = 1
            }
        } else { resizeStart = [:] }
        resize = next
        invalidateLayout()
    }
    func setDrag(excluding next: Set<Int>, insertion nextInsertion: Int?, animated: Bool = true) {
        guard excluded != next || insertion != nextInsertion else { return }
        let frames = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, frame(for: $0)) })
        excluded = next; insertion = nextInsertion
        animateFrames(from: frames, animated: animated)
    }
    private func animateFrames(from frames: [Int: NSRect], animated: Bool) {
        motion?.invalidate(); motion = nil
        startingFrames = frames; progress = animated && !reducesMotion ? 0 : 1
        invalidateLayout()
        guard progress < 1 else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.22)
                self.progress = 1 - pow(1 - t, 3)
                self.invalidateLayout()
                self.collectionView?.layoutSubtreeIfNeeded()
                if t >= 1 { timer.invalidate(); self.motion = nil; self.startingFrames = [:] }
            }
        }
        motion = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func originalIndex(forInsertion position: Int) -> Int {
        let values = remaining
        return values.indices.contains(position) ? values[position] : count
    }
    private func slotFrame(_ slot: Int) -> NSRect {
        NSRect(x: CGFloat(slot % columns) * (itemSize.width + 8), y: CGFloat(slot / columns) * (itemSize.height + 8), width: itemSize.width, height: itemSize.height)
    }
    private func frame(for index: Int) -> NSRect {
        if let resize, let start = resizeStart[index] {
            let end = resize.destination(for: .files)
            let width = floor((end.gridWidth - CGFloat(end.columns - 1) * 8) / CGFloat(end.columns))
            let target = NSRect(x: CGFloat(index % end.columns) * (width + 8),
                                y: CGFloat(index / end.columns) * (end.cardHeight + 8), width: width, height: end.cardHeight)
            let p = resize.progress
            // A row wrap cannot slide diagonally through its neighbours. Fade
            // that item between its two slots while the other cards move.
            let wraps = index / resizeStartColumns != index / end.columns
            let travel = wraps ? (p < 0.5 ? CGFloat(0) : CGFloat(1)) : p
            return NSRect(x: start.minX + (target.minX - start.minX) * travel,
                          y: start.minY + (target.minY - start.minY) * travel,
                          width: start.width + (target.width - start.width) * p,
                          height: start.height + (target.height - start.height) * p)
        }
        let rank = excluded.contains(index) ? min(insertion ?? index, count - excluded.count) : index - excluded.filter { $0 < index }.count
        let slot = rank + ((insertion.map { rank >= $0 } ?? false) && !excluded.contains(index) ? 1 : 0)
        let target = slotFrame(slot)
        guard progress < 1, let start = startingFrames[index], !excluded.contains(index) else { return target }
        return NSRect(x: start.minX + (target.minX - start.minX) * progress,
                      y: start.minY + (target.minY - start.minY) * progress, width: itemSize.width, height: itemSize.height)
    }
    override var collectionViewContentSize: NSSize {
        if resize != nil {
            return NSSize(width: collectionView?.enclosingScrollView?.contentSize.width ?? 616,
                          height: (0..<count).map { frame(for: $0).maxY }.max() ?? itemSize.height)
        }
        let slots = count - excluded.count + (insertion == nil ? 0 : 1)
        let rows = max(1, Int(ceil(Double(slots) / Double(columns))))
        return NSSize(width: collectionView?.enclosingScrollView?.contentSize.width ?? 616,
                      height: CGFloat(rows) * (itemSize.height + 8) - 8)
    }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        (0..<count).compactMap { index in
            guard let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: 0)), attributes.frame.intersects(rect) else { return nil }
            return attributes
        }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item >= 0, indexPath.item < count else { return nil }
        let value = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        value.frame = frame(for: indexPath.item)
        value.alpha = excluded.contains(indexPath.item) ? 0 : 1
        if let resize, indexPath.item / resizeStartColumns != indexPath.item / resize.destination(for: .files).columns {
            value.alpha *= resize.progress < 0.5 ? max(0, 1 - resize.progress * 4) : max(0, (resize.progress - 0.75) * 4)
        }
        return value
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
    override func layoutAttributesForDropTarget(at point: NSPoint) -> NSCollectionViewLayoutAttributes? {
        let index = IndexPath(item: originalIndex(forInsertion: insertionIndex(at: point)), section: 0)
        return layoutAttributesForInterItemGap(before: index)
    }
    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let value = NSCollectionViewLayoutAttributes(forInterItemGapBefore: indexPath)
        let rank = remaining.firstIndex(of: indexPath.item) ?? remaining.count
        value.frame = slotFrame(insertion ?? rank)
        // Keep AppKit's insertion hit target, but draw our inset dashed outline.
        value.alpha = 0
        return value
    }
    func insertionIndex(at point: NSPoint, excluding nextExcluded: Set<Int>? = nil) -> Int {
        let next = nextExcluded ?? excluded
        if next == excluded, let insertion, slotFrame(insertion).contains(point) { return insertion }
        let row = max(0, Int(point.y / (itemSize.height + 8)))
        let column = min(columns, max(0, Int((point.x + itemSize.width / 2) / (itemSize.width + 8))))
        let slot = row * columns + column
        if next != excluded { return min(count - next.count, max(0, slot - next.filter { $0 < slot }.count)) }
        return min(remaining.count, max(0, slot - ((insertion.map { slot > $0 } ?? false) ? 1 : 0)))
    }
}

/// Replace AppKit's blue insertion bar with a quiet, inset dashed outline.
final class ShelfInsertionIndicator: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), xRadius: 8, yRadius: 8)
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 1
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.stroke()
    }
}

final class ShelfCollectionItem: NSCollectionViewItem {
    private var reference: FileReference?
    private var problem: String?
    private var thumbnail: NSImage?
    private var request: QLThumbnailGenerator.Request?
    private var previewTask: Task<Void, Never>?
    private var hosting: NSHostingView<ShelfFileCard>?
    override func loadView() {
        let host = NSHostingView(rootView: ShelfFileCard(name: "", directory: "", image: NSImage(), problem: nil, selected: false))
        host.sizingOptions = []; view = host; hosting = host
    }
    override var isSelected: Bool { didSet { render() } }
    func configure(_ record: FileReference, problem: String?) {
        previewTask?.cancel()
        if let request { QLThumbnailGenerator.shared.cancel(request) }
        request = nil
        reference = record; self.problem = problem
        // Generic type icons do not read a document or download a cloud placeholder.
        let type = record.kind == .folder ? UTType.folder : UTType(filenameExtension: record.url.pathExtension) ?? .data
        thumbnail = NSWorkspace.shared.icon(for: type)
        render()
        guard problem == nil, record.kind == .image || record.kind == .video else { return }
        previewTask = Task { [weak self] in
            let resolved = await Task.detached(priority: .utility) { try? record.resolved() }.value
            guard !Task.isCancelled, let self, self.reference?.id == record.id, let resolved else { return }
            let request = QLThumbnailGenerator.Request(fileAt: resolved.url, size: NSSize(width: 120, height: 80), scale: 2, representationTypes: .thumbnail)
            self.request = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                DispatchQueue.main.async {
                    guard let self, self.reference?.id == record.id, self.request === request, let representation else { return }
                    self.thumbnail = representation.nsImage; self.render()
                }
            }
        }
    }
    private func render() {
        guard let reference else { return }
        hosting?.rootView = ShelfFileCard(name: reference.name, directory: reference.url.deletingLastPathComponent().lastPathComponent,
                                         image: thumbnail ?? NSImage(), problem: problem, selected: isSelected)
        view.toolTip = reference.url.path + (problem.map { "\n" + $0 } ?? "")
        view.setAccessibilityLabel(reference.name + (problem.map { "，" + $0 } ?? ""))
    }
}

private struct ShelfFileCard: View {
    var name: String, directory: String
    var image: NSImage
    var problem: String?
    var selected: Bool
    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 3) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(problem == nil ? 1 : 0.4)
            Text(name).font(BloomTypography.font(11, role: .label)).lineLimit(1).truncationMode(.middle).foregroundStyle(BloomTheme.text)
            if geometry.size.height >= 64 || problem != nil {
            Text(problem == nil ? directory : "原文件不可用").font(BloomTypography.font(9)).lineLimit(1)
                .foregroundStyle(problem == nil ? BloomTheme.muted : Color.orange)
            }
        }.padding(geometry.size.height < 64 ? 6 : 8).frame(width: geometry.size.width, height: geometry.size.height)
        }
            .modifier(BloomLibraryCard(selected: selected))
            .accessibilityElement(children: .ignore).accessibilityLabel(name + (problem.map { "，" + $0 } ?? ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
