import Combine
import JotBloomCore
import SwiftUI

struct InspirationLibraryView: View {
    @ObservedObject var viewModel: InspirationLibraryViewModel
    let onOpen: (Int64) -> Void

    @Environment(\.bloomReduceMotion) private var reduceMotion
    @Environment(\.bloomExpanded) private var expanded
    @State private var listFocused = false
    @StateObject private var libraryDrag = BloomLibraryDrag()

    var body: some View {
        listScreen
            .onPreferenceChange(BloomLibraryFrames.self) { libraryDrag.frames = $0 }
            .onDisappear { libraryDrag.reset() }
            .onChange(of: viewModel.filterCategory) { _ in libraryDrag.reset() }
    }

    private var listScreen: some View {
        VStack(spacing: 8) {
            HStack {
                Text("灵感库").modifier(BloomType(size: expanded ? 20 : 16, weight: .semibold))
                Spacer()
                Text("已加载 \(viewModel.items.count) 条灵感").font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
            }.frame(height: 24)
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 14) {
                    categoryRail
                    Group {
                        if !viewModel.isReady, viewModel.isInitialLoading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityLabel("正在读取灵感库")
                        } else if !viewModel.isReady {
                            initialLoadFailure
                        } else if viewModel.items.isEmpty {
                            Text(viewModel.filterCategory == nil ? "暂无内容" : "这个分类还没有灵感\n可在灵感详情中修改分类")
                                .font(.system(size: 13))
                                .foregroundColor(BloomTheme.muted)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            inspirationList
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .modifier(BloomListFocusOutline(isFocused: listFocused))
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }

            Group {
                if let feedback = viewModel.feedback {
                    listFeedback(feedback)
                } else {
                    Text("↑↓ 选择 · Enter 打开 · ⌘Delete 删除")
                        .font(.system(size: 10)).foregroundStyle(BloomTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }
            }.frame(height: 34).padding(.trailing, 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BloomListFocusTarget(request: viewModel.listFocusRequest, isFocused: $listFocused))
    }

    private var categoryRail: some View {
        ScrollView {
            VStack(spacing: expanded ? 6 : 2) {
                category("全部", symbol: "square.grid.2x2", value: nil)
                category("文章", symbol: "doc.text", value: .article)
                category("作品", symbol: "paintbrush.pointed", value: .work)
                category("产品", symbol: "cube", value: .product)
                category("idea", symbol: "lightbulb", value: .idea)
                Spacer(minLength: 0)
            }
        }.frame(width: 76)
            .scrollIndicators(.hidden)
    }

    private func category(_ title: String, symbol: String, value: InspirationCategory?) -> some View {
        let active = viewModel.filterCategory == value
        return Button { libraryDrag.reset(); viewModel.filter(value) } label: { ZStack {
            Image(systemName: symbol)
                .modifier(BloomType(size: expanded ? 21 : 16))
                .position(x: expanded ? 38 : 17, y: expanded ? 18 : 17)
            Text(title).font(.system(size: 11))
                .position(x: expanded ? 38 : 51, y: expanded ? 43 : 17)
        }
        .frame(width: 76, height: expanded ? 56 : 34)
        .foregroundStyle(active ? BloomTheme.blue : BloomTheme.muted)
        .modifier(BloomSurface(color: active ? BloomTheme.selected : .clear, radius: 18))
        .contentShape(Rectangle()) }
        .buttonStyle(.plain).disabled(viewModel.isReordering)
        .help("显示\(title)灵感")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)灵感")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var inspirationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: expanded ? 6 : 4) {
                    ForEach(viewModel.items) { inspiration in
                        InspirationLibraryRow(
                            inspiration: inspiration,
                            isSelected: viewModel.selectedID == inspiration.id,
                            onSelect: { viewModel.select(inspiration.id) },
                            onOpen: { onOpen(inspiration.id) },
                            onDelete: {
                                viewModel.select(inspiration.id)
                                viewModel.delete(identifier: inspiration.id)
                            },
                            drag: libraryDrag,
                            onMove: { viewModel.move($0, relativeTo: $1, after: $2) }
                        )
                        .id(inspiration.id)
                        .modifier(BloomReorder(id: inspiration.id, drag: libraryDrag))
                        .contextMenu {
                            if let index = viewModel.items.firstIndex(where: { $0.id == inspiration.id }) {
                                Button("上移") { if index > 0 { viewModel.move(inspiration.id, relativeTo: viewModel.items[index - 1].id) } }.disabled(index == 0 || viewModel.isReordering)
                                Button("下移") { if index + 1 < viewModel.items.count { viewModel.move(inspiration.id, relativeTo: viewModel.items[index + 1].id, after: true) } }.disabled(index + 1 == viewModel.items.count || viewModel.isReordering)
                            }
                        }
                        .onAppear {
                            viewModel.loadNextPageIfNeeded(
                                currentItemID: inspiration.id
                            )
                        }
                    }

                    if viewModel.isLoadingNextPage {
                        ProgressView()
                            .controlSize(.small)
                            .frame(height: 28)
                            .accessibilityLabel("正在加载更多灵感")
                    }
                }
            }
            .onAppear { if let id = viewModel.selectedID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: viewModel.selectedID) { identifier in
                guard let identifier else { return }
                if reduceMotion {
                    proxy.scrollTo(identifier, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(identifier, anchor: .center)
                    }
                }
            }
        }
    }

    private var initialLoadFailure: some View {
        VStack(spacing: 8) {
            Text(viewModel.feedback?.message ?? "无法读取灵感库，请重新打开。")
                .font(.system(size: 13))
                .foregroundColor(BloomTheme.muted)
            Button("重试") {
                viewModel.retryInitialLoad()
            }
            .buttonStyle(BloomButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listFeedback(
        _ feedback: InspirationLibraryFeedback
    ) -> some View {
        HStack(spacing: 8) {
            if feedback.kind == .loadMoreError {
                Button(feedback.message) {
                    viewModel.loadNextPage()
                }
                .buttonStyle(.plain)
                .foregroundColor(BloomTheme.blue)
                .accessibilityHint("重新加载下一页")
            } else {
                Text(feedback.message)
                    .foregroundColor(BloomTheme.muted)
            }

            if feedback.kind == .deleted, viewModel.canUndo {
                Button("撤销") {
                    viewModel.undoDeletion()
                }
                .buttonStyle(.plain)
                .fontWeight(.medium)
                .foregroundColor(BloomTheme.blue)
            }
        }
        .font(.system(size: 11))
        .frame(height: 34)
        .accessibilityElement(children: .contain)
    }
}
