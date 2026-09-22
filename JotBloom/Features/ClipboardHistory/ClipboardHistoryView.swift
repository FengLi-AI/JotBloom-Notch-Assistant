import Combine
import JotBloomCore
import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    var promptModel: PromptLibraryViewModel? = nil

    @Environment(\.bloomLibraryResize) private var resize
    @Environment(\.bloomExpanded) private var expanded
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @State private var listFocused = false
    @State private var saving = false
    @State private var openMonths: Set<Date> = []

    var body: some View {
        VStack(spacing: BloomListLayout.spacing) {
            BloomAdaptiveLibrary(kind: .clipboard, expanded: expanded, sidebar: { dateSidebar }, filters: { dateFilters }) { layout in
                Group {
                    if !viewModel.isReady {
                        ProgressView().controlSize(.small).accessibilityLabel("正在读取剪贴板历史")
                    } else if viewModel.visibleItems.isEmpty {
                        Text(viewModel.items.isEmpty ? "暂无内容" : "这个日期没有记录")
                            .font(BloomTypography.font(13)).foregroundStyle(BloomTheme.muted)
                    } else {
                        historyList(layout: layout)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .bloomMeasure("clipboardViewport")
                    .onAppear { viewModel.gridColumnCount = layout.columns }
                    .onChange(of: layout.columns) { viewModel.gridColumnCount = $0 }
            }

            BloomListFooter(help: "←→↑↓：选择卡片\n左键 / Enter：复制并收起\n右键 / ⌘C：复制并保留面板\n更多：保存到提示词、保存到灵感、删除", controlCount: expanded ? 2 : 1) {
                if let feedback = viewModel.feedback, feedback.kind != .copied {
                    feedbackView(feedback)
                } else {
                    Text("\(filterTitle) · \(viewModel.visibleItems.count) 条记录")
                        .bloomMeasure("clipboardFooterText")
                }
            }
        }
        .padding(.horizontal, BloomListLayout.horizontalInset)
        .padding(.vertical, BloomListLayout.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BloomListFocusTarget(request: viewModel.focusRequest, isFocused: $listFocused))
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            viewModel.reconcileDateSelection()
        }
        .onReceive(promptModel?.$busy.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()) { saving = $0 }
    }

    private var months: [Date] {
        Array(Set(viewModel.items.compactMap {
            Calendar.current.dateInterval(of: .month, for: Date(timeIntervalSince1970: Double($0.copiedAtUTCms) / 1000))?.start
        })).sorted(by: >)
    }

    private func dateText(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private var filterTitle: String {
        switch viewModel.dateFilter {
        case .all: return "全部"
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .month(let date): return dateText(date, format: "yyyy年M月")
        case .day(let date): return dateText(date, format: "M月d日")
        }
    }

    private func dateButton(_ title: String, symbol: String, filter: ClipboardDateFilter) -> some View {
        BloomLibrarySidebarButton(title: title, symbol: symbol, active: viewModel.dateFilter == filter) {
            viewModel.filterDate(filter)
        }
    }

    private var dateFilters: some View {
        HStack(spacing: 4) {
            BloomLibraryFilter(title: "全部", active: viewModel.dateFilter == .all) { viewModel.filterDate(.all) }
            BloomLibraryFilter(title: "今天", active: viewModel.dateFilter == .today) { viewModel.filterDate(.today) }
            BloomLibraryFilter(title: "昨天", active: viewModel.dateFilter == .yesterday) { viewModel.filterDate(.yesterday) }
            Menu {
                ForEach(months, id: \.self) { month in
                    Menu(dateText(month, format: "yyyy年M月")) {
                        Button("整月") { viewModel.filterDate(.month(month)) }
                        ForEach(days(in: month), id: \.self) { day in
                            Button(dateText(day, format: "M月d日")) { viewModel.filterDate(.day(day)) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                    Text(isHistoricalFilter ? filterTitle : "按日期")
                }.font(BloomTypography.font(11)).foregroundStyle(isHistoricalFilter ? BloomTheme.blue : BloomTheme.muted)
                    .padding(.horizontal, 8).frame(height: 24)
            }.menuStyle(.borderlessButton).fixedSize().disabled(months.isEmpty)
                .accessibilityLabel("按月份和日期筛选")
            Spacer(minLength: 0)
        }
    }

    private var isHistoricalFilter: Bool {
        switch viewModel.dateFilter { case .month, .day: return true; default: return false }
    }

    private var dateSidebar: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    dateButton("全部", symbol: "square.grid.2x2", filter: .all)
                    dateButton("今天", symbol: "clock", filter: .today)
                    dateButton("昨天", symbol: "clock.arrow.circlepath", filter: .yesterday)
                    Text("按月份").font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
                        .padding(.leading, 9).padding(.top, 12).padding(.bottom, 3)
                    ForEach(months, id: \.self) { month in
                        VStack(spacing: 2) {
                            HStack(spacing: 0) {
                                Button {
                                    if !openMonths.insert(month).inserted { openMonths.remove(month) }
                                } label: {
                                    BloomSymbol(openMonths.contains(month) ? "chevron.down" : "chevron.right", size: 10)
                                        .frame(width: 20, height: 34).contentShape(Rectangle())
                                }.buttonStyle(.plain).foregroundStyle(BloomTheme.muted)
                                    .accessibilityLabel("\(openMonths.contains(month) ? "收起" : "展开")\(dateText(month, format: "yyyy年M月"))")
                                Button {
                                    viewModel.filterDate(.month(month))
                                    openMonths.insert(month)
                                } label: {
                                    Text(dateText(month, format: "yyyy年M月"))
                                        .font(BloomTypography.font(11)).lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityAddTraits(viewModel.dateFilter == .month(month) ? [.isSelected] : [])
                            }.foregroundStyle(BloomTheme.text)
                                .background(viewModel.dateFilter == .month(month) ? BloomTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                .id(month)
                            if openMonths.contains(month) {
                                ForEach(days(in: month), id: \.self) { day in
                                    dateButton(dateText(day, format: "M月d日"), symbol: "calendar", filter: .day(day)).id(day)
                                }
                            }
                        }
                    }
                }.padding(4)
            }
            .onAppear { revealDateFilter(using: proxy) }
            .onChange(of: expanded) { _ in revealDateFilter(using: proxy) }
        }.scrollIndicators(.hidden)
    }

    private func revealDateFilter(using proxy: ScrollViewProxy) {
        switch viewModel.dateFilter {
        case .month(let date): proxy.scrollTo(date, anchor: .top)
        case .day(let date):
            if let month = Calendar.current.dateInterval(of: .month, for: date)?.start { openMonths.insert(month) }
            DispatchQueue.main.async { proxy.scrollTo(date, anchor: .center) }
        default: break
        }
    }

    private func days(in month: Date) -> [Date] {
        Array(Set(viewModel.items.filter { ClipboardDateFilter.month(month).contains($0.copiedAtUTCms) }.map {
            Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double($0.copiedAtUTCms) / 1000))
        })).sorted(by: >)
    }

    private func historyList(layout: LibraryLayoutMetrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: layout.gap), count: layout.columns), spacing: layout.gap) {
                    ForEach(viewModel.visibleItems) { item in
                        ClipboardHistoryRow(
                            item: item,
                            thumbnailURL: viewModel.thumbnailURLs[item.id],
                            isImageUnavailable: viewModel.unavailableImageIDs.contains(
                                item.id
                            ),
                            isSelected: viewModel.selectedID == item.id,
                            didCopyWithCommand: viewModel.copiedItemID == item.id,
                            onSelect: { viewModel.select(item.id) },
                            onCopy: {
                                viewModel.select(item.id)
                                viewModel.copy(
                                    itemID: item.id,
                                    collapseAfterCopy: true
                                )
                            },
                            onDelete: {
                                viewModel.select(item.id)
                                viewModel.delete(itemID: item.id)
                            },
                            onCopyWithoutCollapse: { viewModel.select(item.id); viewModel.copy(itemID: item.id, collapseAfterCopy: false) },
                            onSavePrompt: { promptModel?.saveClipboard(item.id, to: .prompt) },
                            onSaveInspiration: { promptModel?.saveClipboard(item.id, to: .inspiration) },
                            isSaving: saving,
                            cardHeight: layout.cardHeight,
                            compact: !layout.showsSidebar,
                            detailProgress: layout.sidebarReveal
                        )
                        .id(item.id)
                    }
                }
            }
            .onAppear {
                if let id = viewModel.selectedID { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: resize == nil) { settled in
                if settled, let id = viewModel.selectedID { proxy.scrollTo(id) }
            }
            .onChange(of: viewModel.dateFilter) { _ in
                if let id = viewModel.selectedID { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: viewModel.selectedID) { identifier in
                guard let identifier else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo(identifier, anchor: .center)
                }
            }
        }
    }

    private func feedbackView(_ feedback: ClipboardFeedback) -> some View {
        HStack(spacing: 8) {
            Text(feedback.message)
                .font(BloomTypography.font(11))
                .foregroundColor(BloomTheme.muted)

            if feedback.kind == .deleted, viewModel.canUndo {
                Button("撤销") {
                    viewModel.undoDeletion()
                }
                .buttonStyle(.plain)
                .font(BloomTypography.font(11, role: .label))
                .foregroundColor(BloomTheme.blue)
            }
        }
        .help(feedback.message)
    }
}
