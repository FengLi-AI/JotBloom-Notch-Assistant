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

    @Environment(\.bloomExpanded) private var expanded
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button { onSelect(); onCopy() } label: {
                HStack(spacing: 10) {
                    leadingVisual
                        .frame(width: 32, height: 32)
                        .background(BloomTheme.raised, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(primaryText)
                            .modifier(BloomType(size: expanded ? 14 : 12))
                            .foregroundStyle(BloomTheme.text).lineLimit(1)
                        HStack(spacing: 4) {
                            BloomApplicationIcon(bundleIdentifier: item.sourceApplication.bundleIdentifier)
                            Text(item.sourceApplication.name ?? "来源应用未知")
                                .font(.system(size: 10)).foregroundStyle(BloomTheme.muted).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(didCopyWithCommand ? "已复制" : SavedTime.text(item.copiedAtUTCms))
                        .font(.system(size: 10)).foregroundStyle(BloomTheme.muted)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                .padding(.leading, 12).padding(.trailing, 168)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(isImageUnavailable)
            .overlay(BloomSecondaryClick { if !isImageUnavailable { onSelect(); onCopyWithoutCollapse() } })
            HStack(spacing: 4) {
                BloomIconButton(title: "保存到提示词", symbol: item.isFavoritedToPrompt ? "checkmark.circle" : "text.badge.star", active: item.isFavoritedToPrompt,
                    helpText: item.contentType == .image ? "暂不支持图片转存" : item.isFavoritedToPrompt ? "已保存到提示词" : "保存到提示词；配置可用时发送前 2000 字生成标题", action: onSavePrompt)
                    .disabled(item.contentType == .image || isSaving)
                BloomIconButton(title: "保存到灵感", symbol: "leaf", helpText: item.contentType == .image ? "暂不支持图片转存" : "保存到灵感", action: onSaveInspiration)
                    .disabled(item.contentType == .image || isSaving)
                BloomIconButton(title: "复制并保留面板", symbol: didCopyWithCommand ? "checkmark" : "doc.on.doc", active: didCopyWithCommand, action: onCopyWithoutCollapse)
                    .disabled(isImageUnavailable)
                BloomIconButton(title: "删除剪贴板记录", symbol: "trash", destructive: true, helpText: "删除记录，3 秒内可撤销", action: onDelete)
                    .padding(.leading, 8)
            }
            .font(.system(size: 13)).foregroundStyle(BloomTheme.muted).buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: expanded ? 58 : 48)
        .modifier(BloomSurface(color: backgroundColor, radius: expanded ? 20 : 14))
        .contentShape(Rectangle()).onHover { isHovering = $0 }
        .help(helpText).accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel).accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var leadingVisual: some View {
        switch item.contentType {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 16))
                .frame(width: 16)
        case .link:
            Image(systemName: "link")
                .font(.system(size: 16))
                .frame(width: 16)
        case .image:
            if let thumbnailURL,
               let image = NSImage(contentsOf: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundColor(secondaryForegroundColor)
                    .frame(width: 32, height: 32)
            }
        }
    }

    private var primaryText: String {
        switch item.contentType {
        case .text, .link:
            guard let text = item.textContent else { return "" }
            return text.allSatisfy(\.isWhitespace) ? "空白文本" : text
        case .image:
            if isImageUnavailable {
                return "图片不可用"
            }
            guard let width = item.imageWidthPixels,
                  let height = item.imageHeightPixels else {
                return "图片"
            }
            return "图片 \(width) × \(height)"
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return BloomTheme.selected
        }
        if isHovering {
            return BloomTheme.well
        }
        return .clear
    }

    private var foregroundColor: Color {
        isSelected
            ? BloomTheme.text
            : BloomTheme.text
    }

    private var secondaryForegroundColor: Color {
        isSelected
            ? BloomTheme.text
            : BloomTheme.muted
    }

    private var helpText: String {
        item.sourceApplication.name.map { "来源：\($0)" } ?? "来源应用未知"
    }

    private var accessibilityLabel: String {
        let source = item.sourceApplication.name ?? "未知应用"
        return "\(primaryText)，来源 \(source)"
    }

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private extension ClipboardItem {
    var copiedAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(copiedAtUTCms) / 1_000)
    }
}
