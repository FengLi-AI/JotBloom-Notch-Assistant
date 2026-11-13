import AppKit

@MainActor
final class MenuBarController: NSObject {
    var onDevelopmentControls: (() -> Void)?
    let dropView = AssistantStatusDropView(frame: .zero)
    var assistantDrop: AssistantMenuDrop? { didSet { dropView.coordinator = assistantDrop } }
    private let statusItem: NSStatusItem
    private let onToggle: () -> Void
    private let onShow: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(
        onToggle: @escaping () -> Void,
        onShow: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onToggle = onToggle
        self.onShow = onShow
        self.onSettings = onSettings
        self.onQuit = onQuit
        super.init()

        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "萌生")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "萌生 JotBloom"
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        dropView.button = button; dropView.frame = button.bounds; dropView.autoresizingMask = [.width, .height]
        button.addSubview(dropView)
    }

    func invalidate() {
        assistantDrop?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func setVisible(_ visible: Bool) { if !visible { assistantDrop?.cancel() }; statusItem.isVisible = visible }
    func setPending(_ pending: Bool) {
        dropView.pending = pending
        statusItem.button?.toolTip = pending ? "萌生 · 有待处理事项" : "萌生 JotBloom · 拖入文字或文件"
        statusItem.button?.setAccessibilityLabel(pending ? "萌生，有待处理事项" : "萌生")
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(relativeTo: sender)
        } else {
            onToggle()
        }
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "唤起萌生", action: #selector(showPanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        if onDevelopmentControls != nil {
            let item = NSMenuItem(title: "开发与验收…", action: #selector(showDevelopmentControls), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出萌生", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
    }

    @objc private func showDevelopmentControls() { onDevelopmentControls?() }

    @objc
    private func showPanel() {
        onShow()
    }

    @objc
    private func showSettings() { onSettings() }

    @objc
    private func quitApplication() {
        onQuit()
    }
}
