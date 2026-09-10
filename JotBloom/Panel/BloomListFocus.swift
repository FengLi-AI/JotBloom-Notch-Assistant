import AppKit
import SwiftUI

private struct BloomKeyboardNavigationKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var bloomKeyboardNavigation: Bool {
        get { self[BloomKeyboardNavigationKey.self] }
        set { self[BloomKeyboardNavigationKey.self] = newValue }
    }
}

/// A keyboard responder without SwiftUI's whole-container focus halo (macOS 13+).
/// It never intercepts mouse hit testing; the row buttons remain the click targets.
struct BloomListFocusTarget: NSViewRepresentable {
    let request: Int
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> ListKeyboardResponder {
        let view = ListKeyboardResponder()
        view.focusRingType = .none
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ListKeyboardResponder, context: Context) {
        view.onFocusChanged = { isFocused = $0 }
        if view.request != request {
            view.request = request
            view.requestFocus()
        }
    }

    static func dismantleNSView(_ view: ListKeyboardResponder, coordinator: ()) {
        view.onFocusChanged = nil
        view.cancelFocusRequest()
    }
}

final class ListKeyboardResponder: NSView {
    var request: Int?
    var onFocusChanged: ((Bool) -> Void)?
    private var generation = 0
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { requestFocus() } else { cancelFocusRequest() }
    }

    func cancelFocusRequest() { generation += 1 }

    func requestFocus() {
        generation += 1
        let expected = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == expected,
                  let window, window.isVisible else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { notifyFocus(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { notifyFocus(false) }
        return result
    }

    private func notifyFocus(_ focused: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onFocusChanged?(focused && window?.firstResponder === self)
        }
    }
}

struct BloomListFocusOutline: ViewModifier {
    @Environment(\.bloomKeyboardNavigation) private var keyboardNavigation
    let isFocused: Bool
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BloomTheme.blue.opacity(keyboardNavigation && isFocused ? 0.8 : 0), lineWidth: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
