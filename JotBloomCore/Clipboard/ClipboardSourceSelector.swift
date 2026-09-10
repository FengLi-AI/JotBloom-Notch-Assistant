import Foundation

public enum ClipboardSourceSelector {
    public static func select(
        panelIsKey: Bool,
        ownApplication: ClipboardSourceApplication,
        frontmostApplication: ClipboardSourceApplication?
    ) -> ClipboardSourceApplication {
        panelIsKey
            ? ownApplication
            : frontmostApplication
                ?? ClipboardSourceApplication(
                    name: nil,
                    bundleIdentifier: nil
                )
    }
}
