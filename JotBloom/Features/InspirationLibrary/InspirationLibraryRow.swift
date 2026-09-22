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

    var rowHeight: CGFloat = 60
    var compact = true

    @Environment(\.bloomExpanded) private var expanded
    @Environment(\.bloomReduceMotion) private var reduceMotion
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
                        HStack(spacing: 8) {
                            Text(displayTitle)
                                .font(BloomTypography.font(13, role: .label))
                                .foregroundColor(titleColor).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(BloomListLayout.time(inspiration.createdAtUTCms))
                                .font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
                                .fixedSize().help(SavedTime.text(inspiration.createdAtUTCms))
                        }
                        if !summary.isEmpty {
                            Text(summary).font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                                .lineLimit(compact ? 1 : 2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(BloomLibraryPressStyle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help(inspiration.title.isEmpty ? "无标题" : inspiration.title)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            BloomRowMenu(title: "灵感的更多操作") {
                Button("打开灵感") { onSelect(); onOpen() }
                Divider()
                Button("删除灵感", role: .destructive, action: onDelete)
            }
            .padding(.trailing, 6)
        }
        .frame(height: rowHeight)
        .modifier(BloomLibraryCard(selected: isSelected, hovered: isHovering, selectionStyle: .interaction))
        .bloomMeasure("libraryCard.\(inspiration.id)")
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// Avoid showing an automatically generated title twice; stored text stays intact.
    private var summary: String {
        var preview = String(inspiration.body.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let title = inspiration.title.trimmingCharacters(in: separators)
        guard !title.isEmpty else { return preview }
        // The saved body can contain both its original heading and the same first sentence.
        while preview.hasPrefix(title) {
            let rest = String(preview.dropFirst(title.count))
            guard rest.isEmpty || rest.unicodeScalars.first.map({ separators.contains($0) }) == true else { break }
            preview = rest.trimmingCharacters(in: separators)
        }
        return preview
    }

    private var displayTitle: String {
        inspiration.title.isEmpty ? "无标题" : inspiration.title
    }

    private var titleColor: Color {
        if isSelected {
            return BloomTheme.text
        }
        return inspiration.title.isEmpty ? BloomTheme.muted : BloomTheme.text
    }

    private var accessibilityLabel: String {
        "\(displayTitle)，保存于 \(SavedTime.text(inspiration.createdAtUTCms))"
    }

}
