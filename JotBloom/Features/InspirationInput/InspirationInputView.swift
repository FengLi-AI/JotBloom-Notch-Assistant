import AppKit
import Combine
import JotBloomCore
import SwiftUI

struct InspirationInputView: View {
    @ObservedObject var viewModel: InspirationInputViewModel
    let inputHeight: CGFloat
    let isExpanded: Bool

    @FocusState private var inputFocused: Bool
    @State private var nativeEditorHasText = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("捕捉此刻", systemImage: "leaf").font(.system(size: 11, weight: .medium)).foregroundStyle(BloomTheme.blue)
                    Spacer()
                    if viewModel.canUndoClear { Button("撤销清空") { viewModel.undoClear() }.buttonStyle(.plain).font(.system(size: 11)) }
                    BloomIconButton(title: "清空输入", symbol: "trash", destructive: true, helpText: "清空输入，可撤销") {
                        guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                        viewModel.clearInput()
                    }.disabled(viewModel.text.isEmpty || viewModel.isSaving)
                }
                ZStack(alignment: .topLeading) {
                    // Focus alone keeps the hint. Native storage includes IME marked
                    // text before SwiftUI commits it to the draft binding.
                    if viewModel.text.isEmpty && !nativeEditorHasText {
                        Text("有什么想法，先记下来…")
                            .modifier(BloomType(size: isExpanded ? 15 : 14))
                            .foregroundStyle(BloomTheme.muted.opacity(0.65))
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
                        .disabled(!viewModel.isReady)
                        .accessibilityLabel("灵感内容")
                }
            }
            .padding(14)
            .frame(height: inputHeight)
            .modifier(BloomSurface(color: BloomTheme.well))

            if isExpanded { recentInspirations.transition(.opacity) }
            Spacer(minLength: 12)
            actionBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 16).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .onReceive(viewModel.$focusRequest.dropFirst()) { _ in
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
                if let feedback = viewModel.feedback {
                    Text(feedback.message)
                        .font(.system(size: 11))
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

                Button("保存灵感") {
                    guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                    viewModel.save()
                }
                .buttonStyle(BloomButtonStyle(primary: true))
                .disabled(!viewModel.canSave)

                Button("AI探讨") {
                    guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                    viewModel.discuss()
                }
                    .buttonStyle(BloomButtonStyle())
                    .disabled(!viewModel.canSave || viewModel.sendToChat == nil)
                    .help("发送到当前对话：正文及必要上下文会发送给你配置的主模型，可能产生费用")
                    .accessibilityLabel("AI 探讨，发送到当前对话")
            }
            .frame(height: BloomTheme.buttonHeight)
            .padding(.trailing, 32)
    }

    @ViewBuilder
    private var recentInspirations: some View {
        HStack {
            Text("最近灵感").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("先记下，再慢慢整理").font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
        }.padding(.top, 22).padding(.bottom, 10)
        if viewModel.recentInspirations.isEmpty {
            Text("暂无内容")
                .font(.system(size: 13))
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
