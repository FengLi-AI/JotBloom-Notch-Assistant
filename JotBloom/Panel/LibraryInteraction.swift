import AppKit
import JotBloomCore
import SwiftUI

/// Shared space budget for the three compact library pages, in logical points.
enum BloomListLayout {
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 8
    static let spacing: CGFloat = 6
    static let rowSpacing: CGFloat = 8
    static let sidebarWidth: CGFloat = 112
    static let columnSpacing: CGFloat = 12
    static let footerHeight: CGFloat = 24
    static let controlSize: CGFloat = 24

    static func time(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d"
        return formatter.string(from: date)
    }
}

/// Compact panels use a filter strip; browsing panels reveal the navigation rail.
struct BloomAdaptiveLibrary<Sidebar: View, Filters: View, Content: View>: View {
    let kind: LibraryLayoutMetrics.ContentKind
    let expanded: Bool
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let filters: () -> Filters
    @ViewBuilder let content: (LibraryLayoutMetrics) -> Content

    @Environment(\.bloomLibraryResize) private var resize

    var body: some View {
        GeometryReader { geometry in
            let layout = resize?.layout(for: kind) ?? LibraryLayoutMetrics(size: geometry.size, expanded: expanded, kind: kind)
            let reveal = layout.sidebarReveal
            let railWidth = min(112, max(96, geometry.size.width * 0.18))
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .leading) {
                    if reveal < 1 { filters() }
                }.frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                    .opacity(max(0, 1 - reveal * 3)).offset(y: -6 * reveal)
                    .allowsHitTesting(resize == nil && reveal == 0)
                    .accessibilityHidden(reveal > 0)
                HStack(alignment: .top, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if reveal > 0 {
                            sidebar().frame(width: railWidth)
                                .overlay(alignment: .trailing) {
                                    Rectangle().fill(BloomTheme.libraryEdge).frame(width: 0.5).offset(x: 8)
                                }
                        }
                    }.frame(width: railWidth).padding(.trailing, 16)
                        .frame(width: layout.sidebarWidth + 16 * reveal, alignment: .leading)
                        .clipped().opacity(reveal * reveal)
                        .allowsHitTesting(resize == nil && reveal == 1)
                        .accessibilityHidden(reveal < 1)
                    content(layout)
                        .frame(width: layout.gridWidth, height: layout.gridHeight)
                        .clipped()
                        // Column-count changes cannot be interpolated; soften their single reflow.
                        .opacity(resize?.changesColumns(for: kind) == true ? 0.35 + 0.65 * abs(2 * (resize?.progress ?? 1) - 1) : 1)
                }.offset(y: 30 * (1 - reveal))
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
        }
    }
}

struct BloomLibraryFilter: View {
    let title: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(BloomTypography.font(11, role: .label))
                .foregroundStyle(active ? BloomTheme.blue : BloomTheme.muted)
                .padding(.horizontal, 10).frame(height: 24)
                .background(active ? BloomTheme.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

private struct BloomCardPressedKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() || value }
}

/// Uses the button's native pressed state, without adding a gesture that competes with scrolling or dragging.
struct BloomLibraryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.preference(key: BloomCardPressedKey.self, value: configuration.isPressed)
    }
}

struct BloomLibraryCard: ViewModifier {
    enum SelectionStyle { case persistent, interaction }
    @Environment(\.bloomKeyboardNavigation) private var keyboardNavigation
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @State private var pressed = false
    let selected: Bool
    var hovered = false
    var selectionStyle: SelectionStyle = .persistent

    private var highlighted: Bool {
        selectionStyle == .persistent ? selected : pressed || (selected && keyboardNavigation)
    }

    func body(content: Content) -> some View {
        content
            .background(BloomTheme.libraryCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).fill(BloomTheme.blue.opacity(highlighted ? (selectionStyle == .persistent ? 0.07 : 0.035) : hovered ? 0.03 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(highlighted ? BloomTheme.blue.opacity(selectionStyle == .persistent ? 0.8 : 0.4) : BloomTheme.libraryEdge, lineWidth: highlighted ? (selectionStyle == .persistent ? 1.2 : 1) : 0.6)
                    .allowsHitTesting(false)
            }
            .onPreferenceChange(BloomCardPressedKey.self) { pressed = $0 }
            .animation(reduceMotion || selectionStyle == .persistent ? nil : .easeOut(duration: pressed ? 0.06 : 0.18), value: highlighted)
    }
}

struct BloomLibrarySidebarButton: View {
    let title: String
    let symbol: String
    let active: Bool
    var count: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if symbol == "clock" || symbol == "calendar" {
                    Image(systemName: symbol).font(.system(size: 14)).frame(width: 14, height: 14)
                } else {
                    BloomSymbol(symbol, size: 14)
                }
                Text(title).font(BloomTypography.font(12, role: .label)).lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)").font(BloomTypography.font(10)).monospacedDigit()
                }
            }
            .foregroundStyle(active ? BloomTheme.blue : BloomTheme.muted)
            .padding(.horizontal, 9).frame(height: 32)
            .background(active ? BloomTheme.blue.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

struct BloomListFooter<Content: View>: View {
    let help: String
    var controlCount = 1
    @ViewBuilder let content: () -> Content
    @State private var showingHelp = false

    var body: some View {
        HStack(spacing: 8) {
            content()
                .lineLimit(1)
            Spacer(minLength: 0)
            BloomIconButton(title: "操作帮助", symbol: "info.circle", size: BloomListLayout.controlSize) {
                showingHelp.toggle()
            }
            .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                Text(help).font(BloomTypography.font(12)).padding(14)
                    .frame(maxWidth: 320, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(BloomTypography.font(10))
        .foregroundStyle(BloomTheme.muted)
        .padding(.trailing, CGFloat(controlCount) * (BloomListLayout.controlSize + 8))
        .frame(height: BloomListLayout.footerHeight)
    }
}

/// A stable, keyboard-accessible action area without a full row of utility icons.
struct BloomRowMenu<Content: View>: View {
    let title: String
    var size: CGFloat = BloomListLayout.controlSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .medium))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: size, height: size)
        .foregroundStyle(BloomTheme.muted)
        .help(title).accessibilityLabel(title)
    }
}

final class BloomLibraryDrag: ObservableObject {
    var frames: [Int64: CGRect] = [:]
    @Published var source: Int64?
    @Published var target: Int64?
    @Published var after = false
    func update(source: Int64, point: CGPoint) {
        self.source = source
        let match = frames.first { $0.key != source && $0.value.contains(point) }
        target = match?.key
        after = match.map { point.y > $0.value.midY } ?? false
    }
    func reset() { source = nil; target = nil; after = false }
}
struct BloomLibraryFrames: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
struct BloomReorder: ViewModifier {
    let id: Int64
    @ObservedObject var drag: BloomLibraryDrag
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: BloomLibraryFrames.self, value: [id: geometry.frame(in: .global)])
        })
        .opacity(drag.source == id ? 0.65 : 1)
        .overlay(alignment: drag.after ? .bottom : .top) {
            if drag.target == id { Capsule().fill(BloomTheme.blue).frame(height: 2).allowsHitTesting(false) }
        }
    }
}
struct BloomDragHandle: View {
    let id: Int64
    @ObservedObject var drag: BloomLibraryDrag
    let move: (Int64, Int64, Bool) -> Void
    var body: some View {
        BloomSymbol("line.3.horizontal")
            .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            .frame(width: 20, height: 24).contentShape(Rectangle())
            .help("按住拖动排序；右键可上移或下移")
            .accessibilityLabel("拖动排序")
            .accessibilityHint("也可使用记录的菜单上移或下移")
            .highPriorityGesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { drag.update(source: id, point: $0.location) }
                .onEnded { value in
                    drag.update(source: id, point: value.location)
                    if let target = drag.target { move(id, target, drag.after) }
                    drag.reset()
                })
    }
}

/// Intercepts secondary clicks only; left clicks still reach the underlying Button.
struct BloomSecondaryClick: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> SecondaryView { SecondaryView() }
    func updateNSView(_ view: SecondaryView, context: Context) { view.action = action }
    final class SecondaryView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
    }
}
