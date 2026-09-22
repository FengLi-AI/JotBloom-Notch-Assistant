import AppKit
import JotBloomCore
import SwiftUI

struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let thumbnailURL: URL?
    let isImageUnavailable: Bool
    let isSelected: Bool
    let didCopyWithCommand: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    var onCopyWithoutCollapse: () -> Void = {}
    var onSavePrompt: () -> Void = {}
    var onSaveInspiration: () -> Void = {}
    var isSaving = false
    var cardHeight: CGFloat = 96
    var compact = true
    var detailProgress: CGFloat = 0
    @State private var isHovering = false

    private var compactSmall: Bool { compact && cardHeight < 80 }
    private var actionSize: CGFloat { compactSmall ? 20 : 24 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { onSelect(); onCopy() } label: {
                VStack(alignment: .leading, spacing: 6 * detailProgress) {
                        HStack(spacing: 5) {
                            sourceLabel
                            Spacer(minLength: 0)
                            if item.contentType != .text {
                                Text(item.contentType == .image ? "图片" : "链接")
                                    .font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
                            }
                        }.frame(height: 14 * detailProgress).clipped().opacity(detailProgress)
                            .accessibilityHidden(detailProgress < 1)
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(isImageUnavailable)
                .overlay(BloomSecondaryClick { if !isImageUnavailable { onSelect(); onCopyWithoutCollapse() } })
                .help(primaryText + "\n" + SavedTime.text(item.copiedAtUTCms))
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    sourceLabel.opacity(max(0, 1 - detailProgress * 2))
                        .accessibilityHidden(detailProgress >= 0.5)
                    Text(didCopyWithCommand ? "已复制" : BloomListLayout.time(item.copiedAtUTCms))
                        .font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
                        .help(SavedTime.text(item.copiedAtUTCms))
                        .opacity(max(0, detailProgress * 2 - 1))
                        .accessibilityHidden(detailProgress < 0.5)
                }
                Spacer(minLength: 0)
                BloomIconButton(title: "复制并保留面板", symbol: didCopyWithCommand ? "checkmark" : "doc.on.doc", active: didCopyWithCommand, size: actionSize, action: onCopyWithoutCollapse)
                    .disabled(isImageUnavailable)
                BloomRowMenu(title: "剪贴板记录的更多操作", size: actionSize) {
                    Button(item.isFavoritedToPrompt ? "已保存到提示词" : "保存到提示词", action: onSavePrompt)
                        .disabled(item.contentType == .image || isSaving)
                    Button("保存到灵感", action: onSaveInspiration)
                        .disabled(item.contentType == .image || isSaving)
                    Divider()
                    Button("删除剪贴板记录", role: .destructive, action: onDelete)
                }
            }.frame(height: actionSize)
        }.padding(compactSmall ? 6 : 8).frame(height: cardHeight)
            .modifier(BloomLibraryCard(selected: isSelected, hovered: isHovering))
            .onHover { isHovering = $0 }
            .bloomMeasure("clipboardCard.\(item.id)")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(primaryText)，来源 \(item.sourceApplication.name ?? "未知应用")")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var sourceLabel: some View {
        HStack(spacing: 4) {
            BloomApplicationIcon(bundleIdentifier: item.sourceApplication.bundleIdentifier)
            Text(item.sourceApplication.name ?? "未知应用")
                .font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted).lineLimit(1)
            if item.isFavoritedToPrompt { BloomSymbol("text.badge.star", size: 10).foregroundStyle(BloomTheme.blue) }
        }.help("来源：\(item.sourceApplication.name ?? "未知应用")")
    }

    @ViewBuilder private var preview: some View {
        if item.contentType == .image {
            GeometryReader { bounds in
                if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: bounds.size.width, height: bounds.size.height)
                        .background(BloomTheme.surface, in: RoundedRectangle(cornerRadius: 5))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    HStack(spacing: 6) {
                        BloomSymbol("photo", size: 18)
                        Text(isImageUnavailable ? "图片不可用" : "图片")
                            .font(BloomTypography.font(11))
                    }.foregroundStyle(BloomTheme.muted)
                        .frame(width: bounds.size.width, height: bounds.size.height)
                }
            }
        } else {
            Text(primaryText).font(BloomTypography.font(compactSmall ? 11 : 12))
                .foregroundStyle(BloomTheme.text).lineSpacing(2)
                .lineLimit(compact ? (cardHeight >= 110 ? 3 : 2) : 5)
                .fixedSize(horizontal: false, vertical: compactSmall)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var primaryText: String {
        switch item.contentType {
        case .text, .link:
            let text = item.textContent ?? ""
            return text.allSatisfy(\.isWhitespace) ? "空白文本" : text
        case .image:
            if isImageUnavailable { return "图片不可用" }
            guard let width = item.imageWidthPixels, let height = item.imageHeightPixels else { return "图片" }
            return "图片 \(width) × \(height)"
        }
    }
}
