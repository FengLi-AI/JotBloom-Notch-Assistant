import Combine
import JotBloomCore
import SwiftUI

struct InspirationLibraryView: View {
    @ObservedObject var viewModel: InspirationLibraryViewModel
    let onOpen: (Int64) -> Void

    @Environment(\.bloomReduceMotion) private var reduceMotion
    @Environment(\.bloomLibraryResize) private var resize
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
        VStack(spacing: BloomListLayout.spacing) {
            BloomAdaptiveLibrary(kind: .inspirations, expanded: expanded, sidebar: { categoryRail }, filters: { categoryFilters }) { layout in
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
                                .font(BloomTypography.font(13))
                                .foregroundColor(BloomTheme.muted)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            inspirationList(layout: layout)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .bloomMeasure("libraryViewport")
            }

            BloomListFooter(help: "↑↓：选择 · Enter：打开详情\n⌘Delete：删除，可撤销\n按住行左侧拖动柄排序，右键可上移 / 下移") {
                if let feedback = viewModel.feedback {
                    listFeedback(feedback)
                } else {
                    Text("已加载 \(viewModel.items.count) 条灵感")
                        .bloomMeasure("libraryFooterText")
                }
            }
        }
        .padding(.horizontal, BloomListLayout.horizontalInset)
        .padding(.vertical, BloomListLayout.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BloomListFocusTarget(request: viewModel.listFocusRequest, isFocused: $listFocused))
    }

    private var categoryRail: some View {
        ScrollView {
            VStack(spacing: 4) {
                category("全部", symbol: "square.grid.2x2", value: nil)
                category("文章", symbol: "doc.text", value: .article)
                category("作品", symbol: "paintbrush.pointed", value: .work)
                category("产品", symbol: "cube", value: .product)
                category("idea", symbol: "lightbulb", value: .idea)
            }.padding(4)
        }.bloomMeasure("categoryRail")
            .scrollIndicators(.hidden)
    }

    private var categoryFilters: some View {
        HStack(spacing: 4) {
            categoryFilter("全部", value: nil)
            categoryFilter("文章", value: .article)
            categoryFilter("作品", value: .work)
            categoryFilter("产品", value: .product)
            categoryFilter("idea", value: .idea)
            Spacer(minLength: 0)
        }.disabled(viewModel.isReordering)
    }

    private func categoryFilter(_ title: String, value: InspirationCategory?) -> some View {
        BloomLibraryFilter(title: title, active: viewModel.filterCategory == value) {
            libraryDrag.reset(); viewModel.filter(value)
        }
    }

    private func category(_ title: String, symbol: String, value: InspirationCategory?) -> some View {
        BloomLibrarySidebarButton(title: title, symbol: symbol, active: viewModel.filterCategory == value) {
            libraryDrag.reset(); viewModel.filter(value)
        }.disabled(viewModel.isReordering)
            .help("显示\(title)灵感")
            .accessibilityLabel("\(title)灵感")
    }

    private func inspirationList(layout: LibraryLayoutMetrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: BloomListLayout.rowSpacing) {
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
                            onMove: { viewModel.move($0, relativeTo: $1, after: $2) },
                            rowHeight: layout.cardHeight,
                            compact: !layout.showsSidebar
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
            .onChange(of: resize == nil) { settled in if settled, let id = viewModel.selectedID { proxy.scrollTo(id) } }
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
                .font(BloomTypography.font(13))
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
                .font(BloomTypography.font(12, role: .label))
                .foregroundColor(BloomTheme.blue)
            }
        }
        .font(BloomTypography.font(11))
        .help(feedback.message)
        .accessibilityElement(children: .contain)
    }
}
