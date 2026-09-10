import AppKit
import JotBloomCore
import SwiftUI

struct PromptLibraryView: View {
    @ObservedObject var model: PromptLibraryViewModel
    @Environment(\.bloomExpanded) private var expanded
    @State private var listFocused = false
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
                Button { _ = model.returnFromDetail() } label: { Label("返回\(model.editorBackName)", systemImage: "chevron.left") }
                    .buttonStyle(BloomButtonStyle())
                Text("编辑提示词").modifier(BloomType(size: 20, weight: .semibold))
                Spacer()
                Text(model.busy ? "正在处理…" : model.hasUnsavedDetail ? "未保存" : "已保存").font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
            }
            Text("标题").font(.system(size: 12)).foregroundStyle(BloomTheme.muted)
            TextField("提示词标题", text: $model.detailTitle).textFieldStyle(.plain)
                .font(.system(size: 15)).padding(14).modifier(BloomSurface(color: BloomTheme.well, radius: 16))
                .accessibilityLabel("提示词标题").disabled(model.busy)
            Text("正文").font(.system(size: 12)).foregroundStyle(BloomTheme.muted)
            TextEditor(text: $model.detailContent).font(.system(size: 14)).scrollContentBackground(.hidden)
                .focused($detailFocused).onAppear { detailFocused = true }
                .padding(12).modifier(BloomSurface(color: BloomTheme.well, radius: 20))
                .accessibilityLabel("提示词完整正文").disabled(model.busy)
            Text(model.feedback ?? "保存覆盖当前条目；另存会创建独立新条目。")
                .font(.system(size: 11)).foregroundStyle(BloomTheme.muted).lineLimit(2).frame(minHeight: 30, alignment: .leading)
            if model.savedCopyID != nil {
                Button("查看新副本") { model.viewSavedCopy() }
                    .buttonStyle(BloomButtonStyle()).disabled(model.busy)
                    .help("切到全部并定位副本；不会加入常用，未保存的修改须先处理")
            }
            HStack(spacing: 10) {
                Button("保存") { saveDetail(asNew: false) }.buttonStyle(BloomButtonStyle(primary: true)).keyboardShortcut("s", modifiers: .command)
                Button("另存为新提示词") { saveDetail(asNew: true) }.buttonStyle(BloomButtonStyle())
                Button { model.copyDetail() } label: { Label("复制", systemImage: "doc.on.doc") }.buttonStyle(BloomButtonStyle())
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
        VStack(spacing: 8) {
            HStack {
                Text("提示词库").modifier(BloomType(size: expanded ? 20 : 16, weight: .semibold))
                Spacer()
                Text("已加载 \(model.items.count) 条").font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
            }.frame(height: 24)
            Picker("提示词范围", selection: $model.favoritesOnly) {
                Text("全部").tag(false)
                Text("常用").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                .frame(maxWidth: .infinity, alignment: .leading).disabled(model.busy)
            GeometryReader { geometry in
                Group {
                    if model.items.isEmpty {
                        VStack(spacing: 12) {
                            Text(model.isLoading ? "正在读取…" : model.favoritesOnly ? "还没有常用提示词，点列表星标加入" : "暂无内容")
                            Text("从灵感输入或剪贴板保存你的常用提示词").font(.system(size: 11))
                            if model.favoritesOnly { Button("查看全部提示词") { model.favoritesOnly = false }.buttonStyle(BloomButtonStyle()) }
                            if model.feedback != nil { Button("重新读取") { model.refresh() }.buttonStyle(BloomButtonStyle()) }
                        }.foregroundStyle(BloomTheme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: expanded ? 6 : 4) {
                                    ForEach(model.items) { prompt in row(prompt).id(prompt.id) }
                                    if model.hasMore { Button("加载更多") { model.loadMore() }.buttonStyle(BloomButtonStyle()).disabled(model.isLoading) }
                                }
                            }.onAppear { if let id = model.selectedID { proxy.scrollTo(id) } }
                                .onChange(of: model.selectedID) { id in if let id { proxy.scrollTo(id) } }
                                .onChange(of: model.listRevealRequest) { _ in if let id = model.selectedID { proxy.scrollTo(id) } }
                        }
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .modifier(BloomListFocusOutline(isFocused: listFocused && model.editingID == nil))
            }
            HStack(spacing: 8) {
                Text(model.feedback ?? "点击整行 / Enter 编辑 · 复制请点行内按钮 · ⌘⌫ 删除").font(.system(size: 10)).foregroundStyle(BloomTheme.muted).lineLimit(2)
                if model.canUndo { Button("撤销") { model.undoDeletion() }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue) }
                if model.savedCopyID != nil { Button("查看新副本") { model.viewSavedCopy() }.buttonStyle(.plain).foregroundStyle(BloomTheme.blue).disabled(model.busy) }
                Spacer(minLength: 0)
            }.frame(height: 34).padding(.trailing, 32)
        }.padding(.horizontal, 16).padding(.top, 12)
            .background(BloomListFocusTarget(request: model.focusRequest, isFocused: $listFocused))
            .onChange(of: titleFocused) { focused in
                if !focused, model.editingID != nil, !model.flushEdit() { titleFocused = true }
            }
    }
    private func row(_ prompt: Prompt) -> some View {
        HStack(spacing: 8) {
            BloomDragHandle(id: prompt.id, drag: libraryDrag) { model.move($0, relativeTo: $1, after: $2) }.disabled(model.busy)
            if model.editingID == prompt.id {
                TextField("提示词标题", text: $model.editedTitle)
                    .textFieldStyle(.plain).focused($titleFocused)
                    .onSubmit { if model.flushEdit() { titleFocused = false; model.requestFocus() } }
                    .onAppear { titleFocused = true }
                    .accessibilityLabel("提示词标题")
            } else {
                Button { model.openEditor(prompt.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.badge.star").font(.system(size: 16)).foregroundStyle(BloomTheme.blue)
                            .frame(width: 32, height: 32).background(BloomTheme.raised, in: RoundedRectangle(cornerRadius: 11))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(prompt.title).modifier(BloomType(size: expanded ? 14 : 12)).foregroundStyle(BloomTheme.text).lineLimit(1)
                            Text(String(prompt.content.prefix(160))).font(.system(size: 10)).foregroundStyle(BloomTheme.muted).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(SavedTime.text(prompt.createdAtUTCms))
                            .font(.system(size: 10)).foregroundStyle(BloomTheme.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.busy)
            }
            BloomIconButton(title: "复制提示词正文", symbol: "doc.on.doc", helpText: "复制完整正文，不收起面板") { model.copy(prompt.id, collapse: false) }.disabled(model.busy)
            BloomIconButton(title: prompt.isFavorite ? "取消常用" : "加入常用", symbol: prompt.isFavorite ? "star.fill" : "star", active: prompt.isFavorite) { model.toggleFavorite(prompt) }
                .accessibilityValue(prompt.isFavorite ? "已加入常用" : "未加入常用").disabled(model.busy)
            BloomIconButton(title: "删除提示词", symbol: "trash", destructive: true, helpText: "删除提示词，3 秒内可撤销") { model.delete(prompt.id) }
                .padding(.leading, 8).disabled(model.busy)
        }.buttonStyle(.plain).foregroundStyle(BloomTheme.muted)
            .padding(.horizontal, 12).frame(height: expanded ? 58 : 48)
            .modifier(BloomSurface(color: model.selectedID == prompt.id ? BloomTheme.selected : BloomTheme.well, radius: expanded ? 20 : 14))
            .modifier(BloomReorder(id: prompt.id, drag: libraryDrag))
            .contextMenu {
                if let index = model.items.firstIndex(where: { $0.id == prompt.id }) {
                    Button("上移") { if index > 0 { model.move(prompt.id, relativeTo: model.items[index - 1].id) } }.disabled(index == 0 || model.busy)
                    Button("下移") { if index + 1 < model.items.count { model.move(prompt.id, relativeTo: model.items[index + 1].id, after: true) } }.disabled(index + 1 == model.items.count || model.busy)
                }
            }
            .accessibilityElement(children: .contain)
    }
}
