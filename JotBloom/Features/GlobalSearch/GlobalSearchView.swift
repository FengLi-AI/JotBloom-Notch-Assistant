import AppKit
import Combine
import JotBloomCore
import SwiftUI

struct GlobalSearchView: View {
    @ObservedObject var viewModel: GlobalSearchViewModel

    @Environment(\.bloomReduceMotion) private var reduceMotion
    @Environment(\.bloomExpanded) private var expanded
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索全部内容", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(BloomTypography.font(13))
                .padding(.horizontal, 10)
                .frame(height: 36)
                .modifier(BloomSurface(color: BloomTheme.well))
                .focused($inputFocused)
                .accessibilityLabel("全局搜索")

            Spacer().frame(height: 8)

            scopeBar
                .padding(.bottom, 8)

            content

            feedbackRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
        .onReceive(viewModel.$focusRequest.dropFirst()) { _ in
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 6) {
            ForEach(GlobalSearchScope.allCases, id: \.self) { scope in
                Button { viewModel.selectScope(scope) } label: {
                    HStack(spacing: 6) {
                        Text(scope.title)
                        Text(viewModel.phase == .searching || viewModel.phase == .debouncing
                             ? "…" : String(viewModel.count(for: scope)))
                            .monospacedDigit()
                    }
                }
                .buttonStyle(SearchScopeButtonStyle(selected: viewModel.scope == scope))
                .accessibilityLabel("\(scope.title)，\(viewModel.count(for: scope)) 条结果")
                .accessibilityValue(viewModel.scope == scope ? "已选中" : "未选中")
                .help("只查看\(scope.title)搜索结果，保留当前关键词")
            }
        }
        .background(alignment: .leading) {
            BloomSelectionSurface(radius: 10).frame(width: 96, height: 30)
                .offset(x: CGFloat(GlobalSearchScope.allCases.firstIndex(of: viewModel.scope) ?? 0) * 102)
                .animation(reduceMotion ? nil : BloomTheme.selectionAnimation, value: viewModel.scope)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            stateMessage("输入关键词，搜索剪贴板、提示词和灵感（⌘F）")
        case .failure:
            failureState
        case .empty:
            VStack(spacing: 12) {
                Text("没有找到相关内容，试试更短的关键词")
                    .font(BloomTypography.font(13)).foregroundStyle(BloomTheme.muted)
                Button("清除关键词") { viewModel.query = ""; inputFocused = true }
                    .buttonStyle(BloomButtonStyle())
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .debouncing, .searching, .results:
            if viewModel.snapshot.isEmpty {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else if viewModel.visibleResults.isEmpty {
                VStack(spacing: 12) {
                    Text("\(viewModel.scope.title)中没有匹配结果")
                        .font(BloomTypography.font(13)).foregroundStyle(BloomTheme.muted)
                    Button("查看全部结果") { viewModel.selectScope(.all) }
                        .buttonStyle(BloomButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsList
            }
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: expanded ? 6 : 4) {
                    ForEach(SearchResultSource.allCases, id: \.self) { source in
                        searchGroup(source, results: viewModel.displayedResults(for: source))
                    }
                }
                .padding(.bottom, 28)
            }
            .id(viewModel.scope)
            .onAppear { if let id = viewModel.selectedID { proxy.scrollTo(id, anchor: .center) } }
            .task(id: expanded) {
                // The panel animates its height; restore the selected row after
                // the final viewport is laid out, including a return from editing.
                try? await Task.sleep(nanoseconds: reduceMotion ? 20_000_000 : 400_000_000)
                guard !Task.isCancelled, let id = viewModel.selectedID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
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

    @ViewBuilder
    private func searchGroup(
        _ source: SearchResultSource,
        results: [GlobalSearchResult]
    ) -> some View {
        if !results.isEmpty {
            if viewModel.scope == .all {
                HStack {
                    Text(source.displayName)
                        .font(BloomTypography.font(11, role: .label))
                        .foregroundColor(BloomTheme.muted)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if viewModel.snapshot.results(for: source).count > 2,
                       let scope = GlobalSearchScope.allCases.first(where: { $0.source == source }) {
                        Button { viewModel.selectScope(scope) } label: {
                            Text("查看全部 \(viewModel.count(for: scope)) 条 ›")
                                .font(BloomTypography.font(11))
                                .foregroundStyle(BloomTheme.blue)
                                .padding(.horizontal, 8).frame(minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看\(scope.title)全部 \(viewModel.count(for: scope)) 条结果")
                    }
                }
                .frame(minHeight: 28)
                .padding(.horizontal, 8)
            }

            ForEach(results) { result in
                GlobalSearchRow(
                    result: result,
                    isSelected: viewModel.selectedID == result.id,
                    isCopied: viewModel.copiedResultID == result.id,
                    onActivate: { viewModel.activate(result.id) }
                )
                .id(result.id)
            }
        }
    }

    private func stateMessage(_ message: String) -> some View {
        Text(message)
            .font(BloomTypography.font(13))
            .foregroundColor(BloomTheme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failureState: some View {
        VStack(spacing: 8) {
            Text("无法搜索本地内容，请重试")
                .font(BloomTypography.font(13))
                .foregroundColor(BloomTheme.muted)
            Button("重试") {
                viewModel.retry()
            }
            .buttonStyle(BloomButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var feedbackRow: some View {
        if let feedback = viewModel.feedback {
            Text(feedback.message)
                .font(BloomTypography.font(11))
                .foregroundColor(
                    feedback.kind == .error
                        ? Color(nsColor: .systemRed)
                        : BloomTheme.muted
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .bottomLeading)
                .padding(.trailing, 44)
                .accessibilityLabel(feedback.message)
        } else {
            Color.clear
                .frame(height: 34, alignment: .bottom)
                .accessibilityHidden(true)
        }
    }
}

private struct SearchScopeButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.bloomReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BloomTypography.font(12, role: .label))
            .foregroundStyle(selected ? Color.white : BloomTheme.muted)
            .padding(.horizontal, 8).frame(width: 96, height: 30)
            .animation(reduceMotion ? nil : BloomTheme.selectionAnimation, value: selected)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
