import AppKit
import SwiftUI

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
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
            .frame(width: 20, height: 32).contentShape(Rectangle())
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
