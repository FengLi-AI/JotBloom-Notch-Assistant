import SwiftUI

@main
struct JotBloomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }.commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    (ApplicationExtensionHost.shared.module as? JotBloomCompanionExtension)?.openSettings()
                }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
