import JotBloomCore
import SwiftUI

struct PanelRootView: View {
    @ObservedObject var panelState: PanelViewState
    @ObservedObject var inspirationViewModel: InspirationInputViewModel
    @ObservedObject var clipboardViewModel: ClipboardHistoryViewModel
    @ObservedObject var inspirationLibraryViewModel: InspirationLibraryViewModel
    @ObservedObject var globalSearchViewModel: GlobalSearchViewModel
    let onSelectTab: (PanelTab) -> Void
    let onOpenLibraryInspiration: (Int64) -> Void
    let onReturnFromInspirationDetail: () -> Void
    let onSettings: () -> Void
    let onCloseSettings: () -> Void
    let dataDirectory: URL?
    var onExternalLinkOpened: () -> Void = {}
    @Environment(\.openURL) private var systemOpenURL
    var settingsModel: SettingsViewModel? = nil
    var promptModel: PromptLibraryViewModel? = nil
    var chatModel: ChatViewModel? = nil
    var fileShelfModel: FileShelfViewModel? = nil
    var fileShelfDrag: FileShelfDragController? = nil
    var onChatCopy: (String) -> Bool = { _ in false }

    var body: some View {
        GeometryReader { viewport in
        VStack(spacing: 0) {
            PanelChromeView(
                state: panelState,
                onSelectTab: onSelectTab,
                onSettings: onSettings
            )
                .frame(height: panelState.notchHeight)
                .bloomMeasure("chrome")
                .overlay {
                    if panelState.hasPhysicalNotch, let fileShelfDrag {
                        ShelfNotchReceiver(drag: fileShelfDrag).frame(width: panelState.notchWidth)
                    }
                }

            GeometryReader { content in
            Group {
            if (panelState.fileShelfPreview || (!panelState.isSettingsOpen && panelState.selectedTab == .fileShelf)), let fileShelfModel, let fileShelfDrag {
                FileShelfView(model: fileShelfModel, drag: fileShelfDrag)
            } else if panelState.isSettingsOpen {
                PanelSettingsView(state: panelState, dataDirectory: dataDirectory, onBack: onCloseSettings, model: settingsModel)
            } else if isInspirationDetailVisible {
                InspirationDetailView(
                    viewModel: inspirationLibraryViewModel,
                    onBack: onReturnFromInspirationDetail,
                    backDestinationName: detailBackDestinationName
                )
            } else {
                switch panelState.selectedTab {
                case .inspiration:
                    InspirationInputView(
                        viewModel: inspirationViewModel,
                        inputHeight: panelState.inputHeight,
                        isExpanded: panelState.isExpanded
                    )
                case .fileShelf: EmptyView()
                case .clipboard:
                    ClipboardHistoryView(viewModel: clipboardViewModel, promptModel: promptModel)
                case .prompts:
                    if let promptModel { PromptLibraryView(model: promptModel) }
                case .chat:
                    if let chatModel { ChatView(model: chatModel, onCopy: onChatCopy) }
                case .inspirationLibrary:
                    InspirationLibraryView(
                        viewModel: inspirationLibraryViewModel,
                        onOpen: onOpenLibraryInspiration
                    )
                case .globalSearch:
                    GlobalSearchView(viewModel: globalSearchViewModel)
                }
            }
            }.frame(width: content.size.width, height: content.size.height, alignment: .topLeading)
                .clipped()
            }
        }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
        }
        .overlay(alignment: .bottomTrailing) {
            if panelState.fileShelfPreview || (!panelState.isSettingsOpen && !(panelState.selectedTab == .prompts && panelState.isPromptEditorOpen)) { HStack(spacing: 8) {
                if !panelState.fileShelfPreview && panelState.selectedTab == .clipboard && panelState.isExpanded {
                    BloomIconButton(title: "清空剪贴板历史", symbol: "trash", destructive: true, raised: true, size: footerControlSize) { clipboardViewModel.confirmingClear = true }
                        .disabled(clipboardViewModel.items.isEmpty || clipboardViewModel.isClearing)
                }
                BloomIconButton(title: panelState.isExpanded ? "收回面板" : "展开面板", symbol: panelState.isExpanded ? "chevron.up" : "chevron.down", raised: true, size: footerControlSize) {
                panelState.toggleExpansion()
            }
            }
            .padding(.trailing, usesCompactFooter ? BloomListLayout.horizontalInset : 16)
            .bloomMeasure("panelFooterControls")
            .padding(.bottom, usesCompactFooter ? BloomListLayout.verticalInset + 1 : 16)
            }
        }
        .disabled(clipboardViewModel.confirmingClear)
        .accessibilityHidden(clipboardViewModel.confirmingClear)
        .overlay {
            if clipboardViewModel.confirmingClear {
                ZStack {
                    Color.black.opacity(0.45).contentShape(Rectangle()).onTapGesture { }
                    VStack(alignment: .leading, spacing: 18) {
                        Text("清空剪贴板历史？").font(BloomTypography.font(18, role: .label))
                        Text(clipboardViewModel.clearConfirmationMessage).font(BloomTypography.font(13)).foregroundStyle(BloomTheme.muted)
                        HStack {
                            Spacer()
                            Button("取消") { clipboardViewModel.confirmingClear = false }.buttonStyle(BloomButtonStyle()).keyboardShortcut(.cancelAction)
                            Button(clipboardViewModel.isClearing ? "正在清空…" : "确认清空") { clipboardViewModel.clearConfirmed() }.buttonStyle(BloomButtonStyle(primary: true))
                        }.disabled(clipboardViewModel.isClearing)
                    }.padding(24).frame(width: 370).modifier(BloomSurface(color: BloomTheme.well, radius: 24))
                }
            }
        }
        .background(BloomTheme.surface)
        .background(BloomScrollbars(reduceMotion: panelState.reducesMotion))
        .font(BloomTypography.font(13))
        .foregroundStyle(BloomTheme.text)
        .tint(BloomTheme.blue)
        .preferredColorScheme(panelState.preferences.appearance == .dark ? .dark : .light)
        .environment(\.bloomVisible, panelState.isPresented)
        .environment(\.openURL, BloomExternalLinks.action(using: systemOpenURL, onOpened: onExternalLinkOpened))
        .environment(\.bloomExpanded, panelState.isExpanded)
        .environment(\.bloomLibraryResize, panelState.libraryResize)
        .environment(\.bloomReduceMotion, panelState.reducesMotion)
        .environment(\.bloomKeyboardNavigation, panelState.keyboardNavigation)
        .onChange(of: panelState.selectedTab) { tab in
            switch tab {
            case .fileShelf: break
            case .inspiration:
                inspirationViewModel.requestInputFocus()
            case .clipboard:
                clipboardViewModel.requestListFocus()
            case .prompts:
                promptModel?.requestFocus()
            case .chat:
                chatModel?.focus()
            case .inspirationLibrary:
                if inspirationLibraryViewModel.screen == .list {
                    inspirationLibraryViewModel.requestListFocus()
                }
            case .globalSearch:
                if !isInspirationDetailVisible {
                    globalSearchViewModel.requestInputFocus()
                }
            }
        }
    }

    private var usesCompactFooter: Bool {
        panelState.fileShelfPreview || (!panelState.isSettingsOpen && !isInspirationDetailVisible &&
            (panelState.selectedTab == .fileShelf || panelState.selectedTab == .clipboard || panelState.selectedTab == .inspirationLibrary ||
                (panelState.selectedTab == .prompts && !panelState.isPromptEditorOpen)))
    }

    private var footerControlSize: CGFloat {
        usesCompactFooter ? BloomListLayout.controlSize : BloomTheme.buttonHeight
    }

    private var detailBackDestinationName: String {
        switch panelState.inspirationDetailOrigin {
        case .globalSearch:
            return "搜索结果"
        case .inspirationLibrary, .none:
            return "灵感库"
        }
    }

    private var isInspirationDetailVisible: Bool {
        guard inspirationLibraryViewModel.screen == .detail else { return false }
        switch panelState.inspirationDetailOrigin {
        case .inspirationLibrary:
            return panelState.selectedTab == .inspirationLibrary
        case .globalSearch:
            return panelState.selectedTab == .globalSearch
        case .none:
            return false
        }
    }
}

/// Collapse only after the system accepts the external URL handoff.
enum BloomExternalLinks {
    static func action(using system: OpenURLAction, onOpened: @escaping () -> Void) -> OpenURLAction {
        OpenURLAction { url in
            system(url) { accepted in if accepted { onOpened() } }
            return .handled
        }
    }
}

private struct ShelfNotchReceiver: NSViewRepresentable {
    let drag: FileShelfDragController
    func makeNSView(context: Context) -> NotchDropView { let view = NotchDropView(frame: .zero); view.fileShelf = drag; return view }
    func updateNSView(_ view: NotchDropView, context: Context) { view.fileShelf = drag }
}
