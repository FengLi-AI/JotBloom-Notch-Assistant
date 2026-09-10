import JotBloomCore
import SwiftUI

struct RecentInspirationRow: View {
    let inspiration: Inspiration
    @Environment(\.bloomExpanded) private var expanded

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
            Text(inspiration.title.isEmpty ? "无标题" : inspiration.title)
                .modifier(BloomType(size: expanded ? 14 : 12))
                .foregroundColor(BloomTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                Text(inspiration.body.isEmpty ? "留住一个念头" : inspiration.body)
                    .font(.system(size: 11)).foregroundStyle(BloomTheme.muted).lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(
                SavedTime.text(inspiration.createdAtUTCms)
            )
            .font(.system(size: 11))
            .foregroundColor(BloomTheme.muted)
            .lineLimit(1)
        }
        .padding(.horizontal, 14).frame(height: expanded ? 58 : 48)
        .modifier(BloomSurface(color: BloomTheme.well, radius: 16))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
