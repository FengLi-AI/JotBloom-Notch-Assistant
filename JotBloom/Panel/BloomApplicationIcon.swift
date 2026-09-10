import AppKit
import SwiftUI

/// Local application metadata only. Cache misses too, so unknown sources do not
/// perform repeated Launch Services lookups during scrolling or animation.
@MainActor
final class BloomApplicationIconCache {
    static let shared = BloomApplicationIconCache()
    private final class Entry: NSObject {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }
    private let entries = NSCache<NSString, Entry>()
    private let load: (String) -> NSImage?

    init(load: @escaping (String) -> NSImage? = { identifier in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              url.isFileURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }) {
        self.load = load
        entries.countLimit = 64
    }

    func image(for identifier: String?) -> NSImage? {
        guard let identifier, !identifier.isEmpty else { return nil }
        if let cached = entries.object(forKey: identifier as NSString) { return cached.image }
        let image = load(identifier)
        entries.setObject(Entry(image), forKey: identifier as NSString)
        return image
    }
}

struct BloomApplicationIcon: View {
    let bundleIdentifier: String?
    var body: some View {
        if let image = BloomApplicationIconCache.shared.image(for: bundleIdentifier) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(width: 12, height: 12).accessibilityHidden(true)
        }
    }
}
