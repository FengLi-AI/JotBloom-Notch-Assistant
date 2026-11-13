import SwiftUI
import JotBloomCore

@MainActor
final class IslandViewModel: ObservableObject {
    @Published var stage: IslandStage = .hidden
    @Published var geometry = IslandGeometry(width: 0, height: 0, bottomRadius: 0, shoulderRadius: 0)
    @Published var content: IslandContent?
    @Published var contentStage: IslandStage = .compact
    @Published var contentVisible = false
    @Published var contentVersion = UUID()
    @Published var surfaceVisible = false
    @Published var surfaceOpacity: Double = 0
    @Published var floating = false
    @Published var reduced = false
    @Published var notchSize = CGSize.zero
    @Published var glowOpacity: Double = 0
    @Published var running = false
    @Published var offsetY: CGFloat = 0
    let hitRegion = IslandHitRegion()
    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onAction: ((IslandAction) -> Void)?
}

struct AssistantIslandView: View {
    @ObservedObject var model: IslandViewModel
    var body: some View {
        ZStack(alignment: .top) {
            if model.surfaceVisible || !model.reduced {
                if model.reduced {
                    // A stage change cross-fades fixed shapes; there is no size spring.
                    IslandSurface(geometry: model.geometry, floating: model.floating, hitRegion: model.hitRegion)
                        .id(model.stage).transition(.opacity)
                        .animation(nil, value: model.geometry)
                        .opacity(model.surfaceOpacity)
                } else {
                    IslandSurface(geometry: model.geometry, floating: model.floating, hitRegion: model.hitRegion)
                        .opacity(model.surfaceOpacity)
                }
            }
            if model.contentVisible, let content = model.content {
                Group {
                    if model.contentStage == .expanded {
                        IslandExpandedCard(content: content, onAction: { model.onAction?($0) })
                    }
                    else { compact(content) }
                }
                .id(model.contentVersion)
                .padding(.top, model.floating ? 0 : model.notchSize.height)
                .transition(model.reduced ? .opacity : .islandContent)
            }
            if model.stage == .glow, !model.floating {
                IslandNotchRim(width: model.notchSize.width, height: model.notchSize.height)
                    .stroke(IslandTheme.glow, lineWidth: 1.5)
                    .opacity(model.glowOpacity)
                    .allowsHitTesting(false)
            }
            if model.running, model.stage == .hidden, !model.floating {
                Capsule().fill(IslandTheme.glow).frame(width: 40, height: 1.5)
                    .offset(y: model.notchSize.height).allowsHitTesting(false)
            }
        }
        .offset(y: model.offsetY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(IslandTheme.text)
        .environment(\.colorScheme, .dark)
        .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { value in
            if value.translation.height < -24 && abs(value.translation.width) < 80 { model.onDismiss?() }
        })
    }

    private func compact(_ content: IslandContent) -> some View {
        Button { model.onExpand?() } label: {
            HStack(spacing: 9) {
                Circle().fill(IslandTheme.color(content.tone)).frame(width: 6, height: 6)
                Text(content.compactLabel).font(IslandTheme.compactFont).lineLimit(1)
                Spacer(minLength: 4)
                BloomSymbol("chevron.right", size: 12).foregroundStyle(IslandTheme.secondaryText)
            }
            .padding(.horizontal, 18).frame(width: model.geometry.width, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(content.compactText + "，展开")
    }

}

/// Render and measure the same intrinsic layout, including the camera's reserved area.
/// The background must end at this card's padding, not at an estimated text height.
struct IslandExpandedCard: View {
    let content: IslandContent
    var topInset: CGFloat = 0
    var onAction: (IslandAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IslandLayout.sectionSpacing) {
            HStack(spacing: 9) {
                Circle().fill(IslandTheme.color(content.tone)).frame(width: 6, height: 6)
                Text(content.title).font(IslandTheme.titleFont).lineLimit(1)
            }
            if let body = content.body {
                Text(body).font(IslandTheme.bodyFont).foregroundStyle(IslandTheme.secondaryText)
                    .lineSpacing(3).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !content.actions.isEmpty {
                HStack(spacing: IslandLayout.buttonSpacing) {
                    Spacer(minLength: 0)
                    ForEach(Array(content.actions.enumerated()), id: \.element.id) { index, action in
                        Button { onAction(action) } label: {
                            Text(action.title).font(IslandTheme.compactFont)
                                .lineLimit(1).padding(.horizontal, 14)
                                .frame(minWidth: 64, minHeight: IslandLayout.buttonHeight)
                                .foregroundStyle(index == content.actions.count - 1 ? IslandTheme.background : IslandTheme.text)
                                .background(index == content.actions.count - 1 ? IslandTheme.text : IslandTheme.secondaryButton,
                                            in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain).accessibilityLabel(action.title)
                    }
                }
            }
        }
        .padding(IslandLayout.cardInset)
        .padding(.top, topInset)
        .frame(width: IslandLayout.cardWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(IslandTheme.text)
        .environment(\.colorScheme, .dark)
    }
}
