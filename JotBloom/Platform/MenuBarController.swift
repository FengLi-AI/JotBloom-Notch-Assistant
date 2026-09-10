import AppKit

@MainActor
final class MenuBarController: NSObject {
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
    }

    func invalidate() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func setVisible(_ visible: Bool) { statusItem.isVisible = visible }

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
