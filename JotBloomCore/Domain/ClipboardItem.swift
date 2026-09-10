import Foundation

public enum ClipboardContentType: String, CaseIterable, Codable, Sendable {
    case text
    case link
    case image
}

public struct ClipboardSourceApplication: Equatable, Codable, Sendable {
    public let name: String?
    public let bundleIdentifier: String?

    public init(name: String?, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct ClipboardItem: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let contentType: ClipboardContentType
    public let textContent: String?
    public let imageFileName: String?
    public let thumbnailFileName: String?
    public let contentByteCount: Int64
    public let imageSHA256: String?
    public let imageWidthPixels: Int?
    public let imageHeightPixels: Int?
    public let copiedAtUTCms: Int64
    public let sourceApplication: ClipboardSourceApplication
    public let isFavoritedToPrompt: Bool

    public init(
        id: Int64,
        contentType: ClipboardContentType,
        textContent: String?,
        imageFileName: String?,
        thumbnailFileName: String?,
        contentByteCount: Int64,
        imageSHA256: String?,
        imageWidthPixels: Int?,
        imageHeightPixels: Int?,
        copiedAtUTCms: Int64,
        sourceApplication: ClipboardSourceApplication,
        isFavoritedToPrompt: Bool
    ) {
        self.id = id
        self.contentType = contentType
        self.textContent = textContent
        self.imageFileName = imageFileName
        self.thumbnailFileName = thumbnailFileName
        self.contentByteCount = contentByteCount
        self.imageSHA256 = imageSHA256
        self.imageWidthPixels = imageWidthPixels
        self.imageHeightPixels = imageHeightPixels
        self.copiedAtUTCms = copiedAtUTCms
        self.sourceApplication = sourceApplication
        self.isFavoritedToPrompt = isFavoritedToPrompt
    }
}

public enum ClipboardSnapshotContent: Equatable, Sendable {
    case text(String)
    case image(Data)
}

public struct ClipboardSnapshot: Equatable, Sendable {
    public let content: ClipboardSnapshotContent
    public let copiedAtUTCms: Int64
    public let sourceApplication: ClipboardSourceApplication

    public init(
        content: ClipboardSnapshotContent,
        copiedAtUTCms: Int64,
        sourceApplication: ClipboardSourceApplication
    ) {
        self.content = content
        self.copiedAtUTCms = copiedAtUTCms
        self.sourceApplication = sourceApplication
    }
}

public struct NormalizedClipboardImage: Equatable, Sendable {
    public let pngData: Data
    public let thumbnailPNGData: Data
    public let widthPixels: Int
    public let heightPixels: Int
    public let sha256: String

    public var byteCount: Int64 {
        Int64(pngData.count)
    }

    public init(
        pngData: Data,
        thumbnailPNGData: Data,
        widthPixels: Int,
        heightPixels: Int,
        sha256: String
    ) {
        self.pngData = pngData
        self.thumbnailPNGData = thumbnailPNGData
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.sha256 = sha256
    }
}

public enum ClipboardCaptureOutcome: Equatable, Sendable {
    case inserted(ClipboardItem)
    case refreshed(ClipboardItem)
    case skipped
}
