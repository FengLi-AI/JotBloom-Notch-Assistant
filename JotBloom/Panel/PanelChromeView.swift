import JotBloomCore
import SwiftUI

struct PanelChromeView: View {
    @ObservedObject var state: PanelViewState
    let onSelectTab: (PanelTab) -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            slots(Array(state.preferences.order.prefix(3))).frame(maxWidth: .infinity)
            Color.clear.frame(width: state.notchWidth).accessibilityHidden(true)
            HStack(spacing: 3) {
                slots(Array(state.preferences.order.suffix(3)))
                Button { onSelectTab(.globalSearch) } label: {
                    BloomSymbol("magnifyingglass", size: 14)
                        .foregroundStyle(!state.fileShelfPreview && !state.isSettingsOpen && state.selectedTab == .globalSearch ? Color.white : BloomTheme.muted)
                        .frame(width: 26, height: max(14, min(24, state.notchHeight - 8)))
                        .background { if !state.fileShelfPreview && !state.isSettingsOpen && state.selectedTab == .globalSearch { BloomSelectionSurface(radius: 9) } }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("搜索 · ⌘F").accessibilityLabel("搜索")
                Button(action: onSettings) {
                    BloomSymbol("gearshape", size: 14)
                        .foregroundStyle((!state.fileShelfPreview && state.isSettingsOpen) ? Color.white : BloomTheme.muted)
                        .frame(width: 26, height: max(14, min(24, state.notchHeight - 8)))
                        .background { if !state.fileShelfPreview && state.isSettingsOpen { BloomSelectionSurface(radius: 9) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("设置 · ⌘,").accessibilityLabel("设置")
            }.frame(maxWidth: .infinity)
        }.padding(.horizontal, 6).background(BloomTheme.shell)
    }

    private func slots(_ slots: [PanelSlot]) -> some View {
        HStack(spacing: 3) {
            ForEach(slots, id: \.self) { slot in
                BloomTabButton(slot: slot,
                    selected: state.fileShelfPreview ? slot == .fileShelf : !state.isSettingsOpen && state.selectedTab.rawValue == slot.rawValue,
                    height: max(14, min(24, state.notchHeight - 8)),
                    position: (state.preferences.order.firstIndex(of: slot) ?? 0) + 1) {
                    if let tab = PanelTab(rawValue: slot.rawValue) { onSelectTab(tab) }
                }
            }
        }
    }
}

private struct BloomTabButton: View {
    let slot: PanelSlot
    let selected: Bool
    let height: CGFloat
    let position: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 3) {
                    BloomSymbol(slot.symbol, size: 12).accessibilityHidden(true)
                    Text(slot.title).font(BloomTypography.font(10, role: .label))
                }.fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 2) {
                    BloomSymbol(slot.symbol, size: 11).accessibilityHidden(true)
                    Text(slot.title).font(BloomTypography.font(9, role: .label))
                }.fixedSize(horizontal: true, vertical: false)
                Text(slot.title).font(BloomTypography.font(10, role: .label)).fixedSize()
            }
            .padding(.horizontal, 3).frame(maxWidth: .infinity).frame(height: height)
            .foregroundStyle(!slot.isAvailable ? BloomTheme.muted.opacity(0.35) : selected ? Color.white : BloomTheme.muted)
            .background { if selected { BloomSelectionSurface(radius: 9) } else { RoundedRectangle(cornerRadius: 9).fill(hovering ? BloomTheme.surface : .clear) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!slot.isAvailable).onHover { hovering = $0 }
        .help(slot.isAvailable ? "\(slot.title) · ⌘\(position)" : "\(slot.title) · 后续阶段开放")
        .accessibilityLabel(slot.title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
