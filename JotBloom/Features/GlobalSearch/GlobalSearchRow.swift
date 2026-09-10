import AppKit
import JotBloomCore
import SwiftUI

struct GlobalSearchRow: View {
    let result: GlobalSearchResult
    let isSelected: Bool
    let isCopied: Bool
    let onActivate: () -> Void

    @Environment(\.bloomExpanded) private var expanded
    @State private var isHovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 16))
                    .foregroundColor(primaryColor)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(attributedText)
                    .modifier(BloomType(size: expanded ? 14 : 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(isCopied ? "已复制" : relativeTime)
                    .font(.system(size: 11))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity).frame(height: expanded ? 58 : 48)
        .background {
            RoundedRectangle(cornerRadius: expanded ? 20 : 14, style: .continuous)
                .fill(backgroundColor)
                .padding(.horizontal, 1)
        }
        .contentShape(Rectangle())
        .help(result.displayText)
        .accessibilityLabel(result.accessibilityContext)
        .accessibilityHint(actionHint)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { isHovering = $0 }
    }

    private var attributedText: AttributedString {
        var output = AttributedString()
        for segment in result.segments {
            var part = AttributedString(segment.text)
            part.foregroundColor = primaryColor
            if segment.isHighlighted {
                part.backgroundColor = isSelected
                    ? BloomTheme.primary
                    : BloomTheme.blue.opacity(0.2)
                if isSelected {
                    part.foregroundColor = BloomTheme.text
                }
            }
            output.append(part)
        }
        return output
    }

    private var symbolName: String {
        switch result.leadingKind {
        case .text:
            return "text.alignleft"
        case .link:
            return "link"
        case .inspiration:
            return "tray.full"
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

    private var primaryColor: Color {
        isSelected
            ? BloomTheme.text
            : BloomTheme.text
    }

    private var secondaryColor: Color {
        isSelected
            ? BloomTheme.text
            : BloomTheme.muted
    }

    private var actionHint: String {
        switch result.source {
        case .clipboard:
            return "复制并收起面板"
        case .inspiration:
            return "打开灵感详情"
        case .prompt:
            return "打开提示词"
        }
    }

    private var relativeTime: String {
        SavedTime.text(result.timestampUTCms)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
