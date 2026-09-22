import AppKit
import JotBloomCore
import SwiftUI

struct PromptLibraryView: View {
    @ObservedObject var model: PromptLibraryViewModel
    @Environment(\.bloomLibraryResize) private var resize
    @Environment(\.bloomExpanded) private var expanded
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @State private var listFocused = false
    @State private var hoveredPromptID: Int64?
    @StateObject private var libraryDrag = BloomLibraryDrag()
    @FocusState private var titleFocused: Bool
    @FocusState private var detailFocused: Bool
    var body: some View {
        Group { if model.detailID != nil { editor } else { list } }
            .onPreferenceChange(BloomLibraryFrames.self) { libraryDrag.frames = $0 }
            .onDisappear { libraryDrag.reset() }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { _ = model.returnFromDetail() } label: { BloomActionLabel(title: "返回\(model.editorBackName)", symbol: "chevron.left") }
                    .buttonStyle(BloomButtonStyle())
                Text("编辑提示词").modifier(BloomType(size: 20, weight: .semibold))
                Spacer()
                Text(model.busy ? "正在处理…" : model.hasUnsavedDetail ? "未保存" : "已保存").font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            }
            Text("标题").font(BloomTypography.font(12)).foregroundStyle(BloomTheme.muted)
            TextField("提示词标题", text: $model.detailTitle).textFieldStyle(.plain)
                .font(BloomTypography.font(15)).padding(14).modifier(BloomSurface(color: BloomTheme.well, radius: 16))
                .accessibilityLabel("提示词标题").disabled(model.busy)
            Text("正文").font(BloomTypography.font(12)).foregroundStyle(BloomTheme.muted)
            TextEditor(text: $model.detailContent).font(BloomTypography.font(14)).scrollContentBackground(.hidden)
                .focused($detailFocused).onAppear { detailFocused = true }
                .padding(12).modifier(BloomSurface(color: BloomTheme.well, radius: 20))
                .accessibilityLabel("提示词完整正文").disabled(model.busy)
            Text(model.feedback ?? "保存覆盖当前条目；另存会创建独立新条目。")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted).lineLimit(2).frame(minHeight: 30, alignment: .leading)
            if model.savedCopyID != nil {
                Button("查看新副本") { model.viewSavedCopy() }
                    .buttonStyle(BloomButtonStyle()).disabled(model.busy)
                    .help("切到全部并定位副本；不会加入常用，未保存的修改须先处理")
            }
            HStack(spacing: 10) {
                Button("保存") { saveDetail(asNew: false) }.buttonStyle(BloomButtonStyle(primary: true)).keyboardShortcut("s", modifiers: .command)
                Button("另存为新提示词") { saveDetail(asNew: true) }.buttonStyle(BloomButtonStyle())
                Button { model.copyDetail() } label: { BloomActionLabel(title: "复制", symbol: "doc.on.doc") }.buttonStyle(BloomButtonStyle())
                    .help("复制编辑区正文，不保存、不收起面板")
                Spacer(minLength: 0)
                if model.hasUnsavedDetail {
                    Button("放弃修改") { _ = model.returnFromDetail(discard: true) }.buttonStyle(BloomButtonStyle())
                }
            }.disabled(model.busy).padding(.trailing, 32)
        }.padding(16)
    }
    private func saveDetail(asNew: Bool) {
        if let client = NSApp.keyWindow?.firstResponder as? NSTextInputClient, client.hasMarkedText() { return }
        model.saveDetail(asNew: asNew)
    }
    private var list: some View {
        VStack(spacing: BloomListLayout.spacing) {
            BloomAdaptiveLibrary(kind: .prompts, expanded: expanded, sidebar: { promptSidebar }, filters: { promptFilters }) { layout in
                    Group {
                    if model.items.isEmpty {
                        VStack(spacing: 12) {
                            Text(model.isLoading ? "正在读取…" : model.favoritesOnly ? "还没有常用提示词，点列表星标加入" : "暂无内容")
                            Text("从灵感输入或剪贴板保存你的常用提示词").font(BloomTypography.font(11))
                            if model.favoritesOnly { Button("查看全部提示词") { model.favoritesOnly = false }.buttonStyle(BloomButtonStyle()) }
                            if model.feedback != nil { Button("重新读取") { model.refresh() }.buttonStyle(BloomButtonStyle()) }
                        }.foregroundStyle(BloomTheme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 12) {
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: layout.gap), count: layout.columns), spacing: layout.gap) {
                                        ForEach(model.items) { prompt in row(prompt, layout: layout).id(prompt.id) }
                                    }
                                    if model.hasMore { Button("加载更多") { model.loadMore() }.buttonStyle(BloomButtonStyle()).disabled(model.isLoading) }
                                }
                            }.onAppear { if let id = model.selectedID { proxy.scrollTo(id) } }
                                .onChange(of: model.selectedID) { id in if let id { proxy.scrollTo(id) } }
                                .onChange(of: resize == nil) { settled in if settled, let id = model.selectedID { proxy.scrollTo(id) } }
                                .onChange(of: model.listRevealRequest) { _ in if let id = model.selectedID { proxy.scrollTo(id) } }
                        }
                    }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .bloomMeasure("promptViewport")
                    .onAppear { model.gridColumnCount = layout.columns }
                    .onChange(of: layout.columns) { model.gridColumnCount = $0 }
            }
            BloomListFooter(help: "←→↑↓：选择卡片 · 点击 / Enter：编辑\n复制按钮 / ⌘C：复制正文并保留面板\n星标：加入常用 · ⌘Delete：删除\n按住卡片底部拖动柄排序，右键可上移 / 下移") {
                Text(model.feedback ?? "已加载 \(model.items.count) 条")
                    .help(model.feedback ?? "当前列表已加载的提示词数量")
                    .bloomMeasure("promptFooterText")
                if model.canUndo { Button("撤销") { model.undoDeletion() }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue) }
                if model.savedCopyID != nil { Button("查看新副本") { model.viewSavedCopy() }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue).disabled(model.busy) }
            }
        }.padding(.horizontal, BloomListLayout.horizontalInset).padding(.vertical, BloomListLayout.verticalInset)
            .background(BloomListFocusTarget(request: model.focusRequest, isFocused: $listFocused))
            .onChange(of: titleFocused) { focused in
                if !focused, model.editingID != nil, !model.flushEdit() { titleFocused = true }
            }
    }
    private var promptSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("提示词").font(BloomTypography.font(11, role: .label)).foregroundStyle(BloomTheme.muted)
                .padding(.horizontal, 9).padding(.bottom, 8)
            BloomLibrarySidebarButton(title: "全部", symbol: "square.grid.2x2", active: !model.favoritesOnly) {
                libraryDrag.reset(); model.favoritesOnly = false
            }
            BloomLibrarySidebarButton(title: "常用", symbol: "star", active: model.favoritesOnly) {
                libraryDrag.reset(); model.favoritesOnly = true
            }
            Spacer(minLength: 0)
        }.padding(.top, 4).disabled(model.busy)
    }

    private var promptFilters: some View {
        HStack(spacing: 4) {
            BloomLibraryFilter(title: "全部提示词", active: !model.favoritesOnly) { libraryDrag.reset(); model.favoritesOnly = false }
            BloomLibraryFilter(title: "常用", active: model.favoritesOnly) { libraryDrag.reset(); model.favoritesOnly = true }
            Spacer(minLength: 0)
        }.disabled(model.busy)
    }

    private func row(_ prompt: Prompt, layout: LibraryLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.editingID == prompt.id {
                TextField("提示词标题", text: $model.editedTitle)
                    .textFieldStyle(.plain).focused($titleFocused)
                    .onSubmit { if model.flushEdit() { titleFocused = false; model.requestFocus() } }
                    .onAppear { titleFocused = true }
                    .accessibilityLabel("提示词标题")
                    .padding(12).frame(maxHeight: .infinity)
            } else {
                Button { model.openEditor(prompt.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prompt.title).font(BloomTypography.font(12, role: .label))
                            .foregroundStyle(BloomTheme.text).lineLimit(layout.showsSidebar ? 1 : layout.cardHeight >= 100 ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(String(prompt.content.prefix(300))).font(BloomTypography.font(layout.cardHeight >= 84 ? 12 : 11))
                            .foregroundStyle(BloomTheme.muted).lineSpacing(2).lineLimit(layout.showsSidebar && layout.cardHeight >= 112 ? 3 : layout.cardHeight >= 90 ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 10).padding(.top, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                }.buttonStyle(BloomLibraryPressStyle()).disabled(model.busy)
            }
            HStack(spacing: 2) {
                BloomDragHandle(id: prompt.id, drag: libraryDrag) { model.move($0, relativeTo: $1, after: $2) }.disabled(model.busy)
                Text(BloomListLayout.time(prompt.createdAtUTCms))
                    .font(BloomTypography.font(10)).lineLimit(1).help(SavedTime.text(prompt.createdAtUTCms))
                Spacer(minLength: 0)
                BloomIconButton(title: "复制提示词正文", symbol: "doc.on.doc", helpText: "复制完整正文，不收起面板", size: BloomListLayout.controlSize) { model.copy(prompt.id, collapse: false) }.disabled(model.busy)
                BloomIconButton(title: prompt.isFavorite ? "取消常用" : "加入常用", symbol: prompt.isFavorite ? "star.fill" : "star", active: prompt.isFavorite, size: BloomListLayout.controlSize) { model.toggleFavorite(prompt) }
                    .accessibilityValue(prompt.isFavorite ? "已加入常用" : "未加入常用").disabled(model.busy)
                BloomRowMenu(title: "提示词的更多操作") {
                    Button("编辑提示词") { model.openEditor(prompt.id) }
                    Divider()
                    Button("删除提示词", role: .destructive) { model.delete(prompt.id) }
                }.disabled(model.busy)
            }.frame(height: 24).padding(.horizontal, 8).padding(.bottom, 5)
        }.foregroundStyle(BloomTheme.muted).frame(height: layout.cardHeight)
            .modifier(BloomLibraryCard(selected: model.selectedID == prompt.id, hovered: hoveredPromptID == prompt.id, selectionStyle: .interaction))
            .onHover { hoveredPromptID = $0 ? prompt.id : nil }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(model.selectedID == prompt.id ? [.isSelected] : [])
            .bloomMeasure("promptCard.\(prompt.id)")
            .modifier(BloomReorder(id: prompt.id, drag: libraryDrag))
            .contextMenu {
                if let index = model.items.firstIndex(where: { $0.id == prompt.id }) {
                    Button("上移") { if index > 0 { model.move(prompt.id, relativeTo: model.items[index - 1].id) } }.disabled(index == 0 || model.busy)
                    Button("下移") { if index + 1 < model.items.count { model.move(prompt.id, relativeTo: model.items[index + 1].id, after: true) } }.disabled(index + 1 == model.items.count || model.busy)
                }
            }
    }
}
