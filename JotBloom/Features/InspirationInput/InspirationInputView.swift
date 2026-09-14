import AppKit
import Combine
import JotBloomCore
import SwiftUI

struct InspirationInputView: View {
    @ObservedObject var viewModel: InspirationInputViewModel
    let inputHeight: CGFloat
    let isExpanded: Bool

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var inputFocused: Bool
    @State private var nativeEditorHasText = false

    var body: some View {
        GeometryReader { viewport in
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    BloomActionLabel(title: "捕捉此刻", symbol: "leaf").font(BloomTypography.font(11, role: .label)).foregroundStyle(BloomTheme.blue)
                    Spacer()
                    if viewModel.canUndoClear { Button("撤销清空") { viewModel.undoClear() }.buttonStyle(.plain).font(BloomTypography.font(11)) }
                    BloomIconButton(title: "清空输入", symbol: "trash", destructive: true, helpText: "清空输入，可撤销", size: 22) {
                        guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                        viewModel.clearInput()
                    }.disabled(viewModel.text.isEmpty || viewModel.isSaving)
                }.frame(height: 22).bloomMeasure("captureHeader")
                ZStack(alignment: .topLeading) {
                    // Focus alone keeps the hint. Native storage includes IME marked
                    // text before SwiftUI commits it to the draft binding.
                    if viewModel.text.isEmpty && !nativeEditorHasText {
                        Text("有什么想法，先记下来…")
                            .modifier(BloomType(size: isExpanded ? 15 : 14))
                            .foregroundStyle(BloomTheme.muted.opacity(colorScheme == .dark ? 0.65 : 1))
                            // Match macOS TextEditor's first line: 5pt line-fragment padding,
                            // with no extra vertical inset. Share its animated font size below.
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $viewModel.text)
                        .modifier(BloomType(size: isExpanded ? 15 : 14))
                        .scrollContentBackground(.hidden)
                        .focused($inputFocused)
                        .task(id: viewModel.focusRequest) {
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            inputFocused = true
                        }
                        .disabled(!viewModel.isReady)
                        .accessibilityLabel("灵感内容")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(height: isExpanded ? inputHeight : max(60, viewport.size.height - 12 - 16 - 12 - BloomTheme.buttonHeight))
            .modifier(BloomSurface(color: BloomTheme.well, radius: 20))
            .bloomMeasure("inspirationInput")

            if isExpanded { recentInspirations.transition(.opacity) }
            if isExpanded { Spacer(minLength: 12) } else { Color.clear.frame(height: 12) }
            actionBar.bloomMeasure("inspirationActions")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification)) { notification in
            guard inputFocused,
                  let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  let storage = notification.object as? NSTextStorage,
                  storage === editor.textStorage else { return }
            // Read after this editing transaction; never mutate text or interrupt IME.
            DispatchQueue.main.async {
                guard inputFocused else { return }
                nativeEditorHasText = storage.length > 0
            }
        }
        .onChange(of: inputFocused) { focused in
            if !focused { nativeEditorHasText = false }
        }

    }

    private var actionBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
                if let feedback = viewModel.feedback {
                    Text(feedback.message)
                        .font(BloomTypography.font(11))
                        .foregroundColor(BloomTheme.muted)
                        .lineLimit(1)
                        .transition(.opacity)
                        .accessibilityLabel(feedback.message)
                        .help(feedback.message)
                }

                Spacer(minLength: 0)

                Button("保存到提示词") {
                    guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                    viewModel.saveToPrompt()
                }
                .buttonStyle(BloomButtonStyle())
                .disabled(!viewModel.canSave)
                .help("保存完整原文；配置可用时将发送前 2000 字生成标题")

                Button {
                    guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                    viewModel.save()
                } label: { BloomActionLabel(title: "保存灵感", symbol: "checkmark") }
                .buttonStyle(BloomButtonStyle(primary: true))
                .disabled(!viewModel.canSave)

                Button {
                    guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                    viewModel.discuss()
                } label: { BloomActionLabel(title: "AI 探讨", symbol: "sparkles") }
                    .buttonStyle(BloomButtonStyle(ai: true))
                    .disabled(!viewModel.canSave || viewModel.sendToChat == nil)
                    .help("发送到当前对话：正文及必要上下文会发送给你配置的主模型，可能产生费用")
                    .accessibilityLabel("AI 探讨，发送到当前对话")
            }
            .frame(height: BloomTheme.buttonHeight)
            .padding(.trailing, 42)
    }

    @ViewBuilder
    private var recentInspirations: some View {
        HStack {
            Text("最近灵感").font(BloomTypography.font(13, role: .label))
            Spacer()
            Text("先记下，再慢慢整理").font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
        }.padding(.top, 22).padding(.bottom, 10)
        if viewModel.recentInspirations.isEmpty {
            Text("暂无内容")
                .font(BloomTypography.font(13))
                .foregroundColor(BloomTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.recentInspirations) { inspiration in
                        RecentInspirationRow(inspiration: inspiration)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 26)
        }
    }
}
