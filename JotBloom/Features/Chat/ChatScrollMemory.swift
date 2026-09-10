import AppKit
import JotBloomCore
import SwiftUI

/// Preserve the actual clip offset; a row ID alone loses the position inside long replies.
struct ChatScrollMemory: NSViewRepresentable {
    let model: ChatViewModel
    var onUserScroll: (Bool) -> Void
    var onAttach: (NSScrollView) -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; view.onUserScroll = onUserScroll; view.onAttach = onAttach; return view }
    func updateNSView(_ view: Probe, context: Context) { view.onUserScroll = onUserScroll }
    final class Probe: NSView {
        weak var model: ChatViewModel?
        var onUserScroll: ((Bool) -> Void)?
        var onAttach: ((NSScrollView) -> Void)?
        private var observation: NSObjectProtocol?
        private var restored = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, observation == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        private func attach() {
            guard let scroll = enclosingScrollView, let model else { return }
            onAttach?(scroll)
            let clip = scroll.contentView
            let offset = model.scrollOffset
            clip.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, self.restored, let scroll, let model = self.model else { return }
                    model.scrollOffset = scroll.contentView.bounds.minY
                    let type = NSApp.currentEvent?.type
                    if type == .scrollWheel || type == .keyDown {
                        let end = scroll.documentView?.bounds.maxY ?? 0
                        self.onUserScroll?(end - scroll.contentView.bounds.maxY < 45)
                    }
                }
            }
            DispatchQueue.main.async { [weak self, weak scroll] in
                guard let self, let scroll else { return }
                if !model.followingLatest, let offset {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: offset)); scroll.reflectScrolledClipView(scroll.contentView)
                }
                restored = true
            }
        }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
