import Foundation
@testable import JotBloomCore

enum ClipboardTestFixtures {
    static func item(
        id: Int64,
        type: ClipboardContentType = .text,
        text: String? = "item",
        imageFileName: String? = nil,
        thumbnailFileName: String? = nil,
        byteCount: Int64 = 4,
        sha256: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        copiedAt: Int64,
        sourceName: String? = "Test App",
        bundleIdentifier: String? = "com.example.test",
        favorited: Bool = false
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            contentType: type,
            textContent: type == .image ? nil : text,
            imageFileName: type == .image ? imageFileName : nil,
            thumbnailFileName: type == .image ? thumbnailFileName : nil,
            contentByteCount: byteCount,
            imageSHA256: type == .image ? sha256 : nil,
            imageWidthPixels: type == .image ? width : nil,
            imageHeightPixels: type == .image ? height : nil,
            copiedAtUTCms: copiedAt,
            sourceApplication: ClipboardSourceApplication(
                name: sourceName,
                bundleIdentifier: bundleIdentifier
            ),
            isFavoritedToPrompt: favorited
        )
    }
}
