import AppKit
import JotBloomCore

@MainActor
final class ClipboardSourceApplicationProvider {
    private let ownBundleIdentifier: String
    private let ownApplicationName: String
    private let isJotBloomPanelKey: () -> Bool

    init(
        ownBundleIdentifier: String = Bundle.main.bundleIdentifier
            ?? "com.jotbloom.mengsheng",
        ownApplicationName: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String ?? "萌生 JotBloom",
        isJotBloomPanelKey: @escaping () -> Bool
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.ownApplicationName = ownApplicationName
        self.isJotBloomPanelKey = isJotBloomPanelKey
    }

    func currentSource() -> ClipboardSourceApplication {
        let application = NSWorkspace.shared.frontmostApplication
        let frontmost = application.map {
            ClipboardSourceApplication(
                name: $0.localizedName,
                bundleIdentifier: $0.bundleIdentifier
            )
        }
        return ClipboardSourceSelector.select(
            panelIsKey: isJotBloomPanelKey(),
            ownApplication: ClipboardSourceApplication(
                name: ownApplicationName,
                bundleIdentifier: ownBundleIdentifier
            ),
            frontmostApplication: frontmost
        )
    }
}
