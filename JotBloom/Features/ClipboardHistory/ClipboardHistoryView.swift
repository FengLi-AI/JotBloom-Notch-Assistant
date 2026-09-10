import Combine
import JotBloomCore
import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    var promptModel: PromptLibraryViewModel? = nil

    @Environment(\.bloomExpanded) private var expanded
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @State private var listFocused = false
    @State private var saving = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("剪贴板").modifier(BloomType(size: expanded ? 20 : 16, weight: .semibold))
                Spacer()
                Text("\(viewModel.items.count) 条记录").font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
            }.frame(height: 24)
            GeometryReader { geometry in
                Group {
                    if !viewModel.isReady {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("正在读取剪贴板历史")
                    } else if viewModel.items.isEmpty {
                        Text("暂无内容")
                            .font(.system(size: 13))
                            .foregroundColor(BloomTheme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        historyList
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .modifier(BloomListFocusOutline(isFocused: listFocused))
            }

            Group {
                if let feedback = viewModel.feedback,
                   feedback.kind != .copied {
                    feedbackView(feedback)
                        .transition(.opacity)
                } else {
                    Text("左键复制并收起 · 右键 / ⌘C 复制不收起")
                        .font(.system(size: 10)).foregroundStyle(BloomTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }
            }.frame(height: 34).padding(.trailing, expanded ? 80 : 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BloomListFocusTarget(request: viewModel.focusRequest, isFocused: $listFocused))
        .onReceive(promptModel?.$busy.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()) { saving = $0 }
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: expanded ? 6 : 4) {
                    ForEach(viewModel.items) { item in
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
                            onCopyWithoutCollapse: { viewModel.copy(itemID: item.id, collapseAfterCopy: false) },
                            onSavePrompt: { promptModel?.saveClipboard(item.id, to: .prompt) },
                            onSaveInspiration: { promptModel?.saveClipboard(item.id, to: .inspiration) },
                            isSaving: saving
                        )
                        .id(item.id)
                    }
                }
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
                .font(.system(size: 11))
                .foregroundColor(BloomTheme.muted)

            if feedback.kind == .deleted, viewModel.canUndo {
                Button("撤销") {
                    viewModel.undoDeletion()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(BloomTheme.blue)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}
