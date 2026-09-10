import Foundation
import UniformTypeIdentifiers

public enum ClipboardPasteboardTypes {
    public static let concealed = "org.nspasteboard.ConcealedType"
    public static let string = "public.utf8-plain-text"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let jpeg = "public.jpeg"

    public static let unsupportedExactTypes: Set<String> = [
        "public.file-url",
        "NSFilenamesPboardType",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.NSFilePromiseItemData",
        "com.apple.flat-rtfd",
        "com.apple.rtfd",
        "public.rtfd",
        "com.apple.webarchive",
        "com.adobe.pdf",
        "public.pdf"
    ]
}

@MainActor
public protocol ClipboardPasteboardAccessing: AnyObject {
    var changeCount: Int { get }
    func itemTypes() -> [[String]]
    func string(forType rawType: String, itemAt index: Int) -> String?
    func data(forType rawType: String, itemAt index: Int) -> Data?
}

@MainActor
public protocol ClipboardWriting: AnyObject {
    @discardableResult
    func writeText(_ text: String) throws -> Int

    @discardableResult
    func writePNGData(_ data: Data) throws -> Int
}

public enum ClipboardWriteError: Error, Equatable, LocalizedError {
    case writeFailed

    public var errorDescription: String? {
        "无法写入系统剪贴板。"
    }
}

@MainActor
public struct ClipboardSnapshotReader {
    public init() {}

    public func readSnapshot(
        from pasteboard: ClipboardPasteboardAccessing,
        expectedChangeCount: Int,
        copiedAtUTCms: Int64,
        sourceApplication: ClipboardSourceApplication
    ) -> ClipboardSnapshot? {
        guard pasteboard.changeCount == expectedChangeCount else {
            return nil
        }

        let allItemTypes = pasteboard.itemTypes()
        guard !allItemTypes.isEmpty,
              !containsConcealedType(allItemTypes),
              !containsUnsupportedType(allItemTypes),
              let firstItemTypes = allItemTypes.first else {
            return nil
        }

        let content: ClipboardSnapshotContent?
        if let imageType = preferredImageType(in: firstItemTypes),
           let data = pasteboard.data(forType: imageType, itemAt: 0),
           !data.isEmpty {
            content = .image(data)
        } else if firstItemTypes.contains(ClipboardPasteboardTypes.string),
                  let text = pasteboard.string(
                      forType: ClipboardPasteboardTypes.string,
                      itemAt: 0
                  ) {
            content = .text(text)
        } else {
            content = nil
        }

        guard pasteboard.changeCount == expectedChangeCount,
              let content else {
            return nil
        }
        return ClipboardSnapshot(
            content: content,
            copiedAtUTCms: copiedAtUTCms,
            sourceApplication: sourceApplication
        )
    }

    private func containsConcealedType(_ itemTypes: [[String]]) -> Bool {
        itemTypes.joined().contains(ClipboardPasteboardTypes.concealed)
    }

    private func containsUnsupportedType(_ itemTypes: [[String]]) -> Bool {
        for rawType in itemTypes.joined() {
            if ClipboardPasteboardTypes.unsupportedExactTypes.contains(rawType) {
                return true
            }
            guard let type = UTType(rawType) else { continue }
            if type.conforms(to: .fileURL)
                || type.conforms(to: .folder)
                || type.conforms(to: .audio)
                || type.conforms(to: .movie) {
                return true
            }
        }
        return false
    }

    private func preferredImageType(in itemTypes: [String]) -> String? {
        [
            ClipboardPasteboardTypes.png,
            ClipboardPasteboardTypes.tiff,
            ClipboardPasteboardTypes.jpeg
        ].first(where: itemTypes.contains)
    }
}
