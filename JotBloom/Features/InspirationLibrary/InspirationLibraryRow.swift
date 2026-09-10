import AppKit
import JotBloomCore
import SwiftUI

struct InspirationLibraryRow: View {
    let inspiration: Inspiration
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    var drag: BloomLibraryDrag? = nil
    var onMove: ((Int64, Int64, Bool) -> Void)? = nil

    @Environment(\.bloomExpanded) private var expanded
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                onSelect()
                onOpen()
            } label: {
                HStack(spacing: 8) {
                    if let drag, let onMove { BloomDragHandle(id: inspiration.id, drag: drag, move: onMove) }
                    VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .modifier(BloomType(size: expanded ? 14 : 12))
                        .foregroundColor(titleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(inspiration.body.isEmpty ? "留住一个念头" : inspiration.body)
                        .font(.system(size: 11)).foregroundStyle(BloomTheme.muted).lineLimit(1)
                    }

                    Text(SavedTime.text(inspiration.createdAtUTCms))
                    .font(.system(size: 11))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.leading, 14)
                .padding(.trailing, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help(inspiration.title.isEmpty ? "无标题" : inspiration.title)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            BloomIconButton(title: "删除灵感", symbol: "trash", destructive: true, helpText: "删除灵感，3 秒内可撤销", action: onDelete)
            .padding(.trailing, 8)
        }
        .frame(height: expanded ? 58 : 48)
        .background {
            RoundedRectangle(cornerRadius: expanded ? 20 : 14, style: .continuous)
                .fill(backgroundColor)
                .padding(.horizontal, 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var displayTitle: String {
        inspiration.title.isEmpty ? "无标题" : inspiration.title
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

    private var titleColor: Color {
        if isSelected {
            return BloomTheme.text
        }
        return inspiration.title.isEmpty ? BloomTheme.muted : BloomTheme.text
    }

    private var secondaryColor: Color {
        isSelected
            ? BloomTheme.text
            : BloomTheme.muted
    }

    private var accessibilityLabel: String {
        "\(displayTitle)，保存于 \(SavedTime.text(inspiration.createdAtUTCms))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
