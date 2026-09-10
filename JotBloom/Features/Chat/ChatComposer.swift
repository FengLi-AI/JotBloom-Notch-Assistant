import AppKit
import SwiftUI

struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var enabled: Bool
    var onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let editor = ChatTextView(frame: .zero)
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.drawsBackground = false; editor.textColor = NSColor(BloomTheme.text)
        editor.insertionPointColor = NSColor(BloomTheme.blue)
        editor.font = .systemFont(ofSize: 14); editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator; editor.send = onSend
        editor.setAccessibilityLabel("对话输入，回车发送，Shift 回车换行")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? ChatTextView else { return }
        editor.send = onSend; editor.isEditable = enabled
        if !editor.hasMarkedText(), editor.string != text { editor.string = text }
        if context.coordinator.focus != focusRequest {
            context.coordinator.focus = focusRequest
            DispatchQueue.main.async { if editor.window?.isVisible == true { editor.window?.makeFirstResponder(editor) } }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer
        var focus = -1
        init(_ parent: ChatComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

final class ChatTextView: NSTextView {
    var send: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if !hasMarkedText(), !event.modifierFlags.contains(.shift) { send?(); return }
        }
        super.keyDown(with: event)
    }
}
