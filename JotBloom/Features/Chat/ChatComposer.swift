import AppKit
import SwiftUI

struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var enabled: Bool
    var onSend: () -> Void
    var onFiles: (([URL]) -> Void)? = nil
    var onHover: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let editor = ChatTextView(frame: .zero)
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.drawsBackground = false; editor.textColor = NSColor(BloomTheme.text)
        editor.insertionPointColor = NSColor(BloomTheme.blue)
        editor.font = BloomTypography.nsFont(14); editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator; editor.send = onSend; editor.receiveFiles = onFiles; editor.hover = onHover
        editor.registerForDraggedTypes([.fileURL])
        editor.setAccessibilityLabel("助手输入，回车发送，Shift 回车换行")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? ChatTextView else { return }
        editor.send = onSend; editor.receiveFiles = onFiles; editor.hover = onHover; editor.isEditable = enabled
        editor.textColor = NSColor(BloomTheme.text)
        editor.insertionPointColor = NSColor(BloomTheme.blue)
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
    var receiveFiles: (([URL]) -> Void)?
    var hover: (Bool) -> Void = { _ in }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true { return draggingUpdated(sender) }
        let operation = super.draggingEntered(sender)
        hover(!operation.isEmpty); return operation
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            let accepts = isEditable && receiveFiles != nil && sender.draggingSourceOperationMask.contains(.copy)
            hover(accepts); return accepts ? .copy : []
        }
        let operation = super.draggingUpdated(sender)
        hover(!operation.isEmpty); return operation
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover(false); super.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            return isEditable && receiveFiles != nil && sender.draggingSourceOperationMask.contains(.copy)
        }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hover(false) }
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            guard isEditable, let receiveFiles else { return false }
            let urls = FileShelfDragController.urls(sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            receiveFiles(urls); return true
        }
        return super.performDragOperation(sender)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if !hasMarkedText(), !event.modifierFlags.contains(.shift) { send?(); return }
        }
        super.keyDown(with: event)
    }
}
