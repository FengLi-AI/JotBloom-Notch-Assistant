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
                Button(action: onSettings) {
                    Image(systemName: "gearshape").font(.system(size: 14))
                        .foregroundStyle(state.isSettingsOpen ? BloomTheme.blue : BloomTheme.muted)
                        .frame(width: 26, height: min(28, state.notchHeight - 4))
                        .background(state.isSettingsOpen ? BloomTheme.selected : .clear, in: Capsule())
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
                    selected: !state.isSettingsOpen && state.selectedTab.rawValue == slot.rawValue,
                    height: min(28, state.notchHeight - 4),
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
                    Image(systemName: slot.symbol).font(.system(size: 12))
                    Text(slot.title).font(.system(size: 10, weight: .medium)).fixedSize()
                }
                Image(systemName: slot.symbol).font(.system(size: 14))
            }
            .padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: height)
            .foregroundStyle(!slot.isAvailable ? BloomTheme.muted.opacity(0.35) : selected ? BloomTheme.blue : BloomTheme.muted)
            .modifier(BloomSurface(color: selected ? BloomTheme.selected : hovering ? BloomTheme.surface : .clear, radius: 18))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!slot.isAvailable).onHover { hovering = $0 }
        .help(slot.isAvailable ? "\(slot.title) · ⌘\(position)" : "\(slot.title) · 后续阶段开放")
        .accessibilityLabel(slot.title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
