import AppKit
import JotBloomCore

@MainActor
final class SystemPasteboardClient: ClipboardPasteboardAccessing, ClipboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func itemTypes() -> [[String]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.map(\.rawValue)
        }
    }

    func string(forType rawType: String, itemAt index: Int) -> String? {
        guard let items = pasteboard.pasteboardItems,
              items.indices.contains(index) else {
            return nil
        }
        return items[index].string(
            forType: NSPasteboard.PasteboardType(rawType)
        )
    }

    func data(forType rawType: String, itemAt index: Int) -> Data? {
        guard let items = pasteboard.pasteboardItems,
              items.indices.contains(index) else {
            return nil
        }
        return items[index].data(
            forType: NSPasteboard.PasteboardType(rawType)
        )
    }

    @discardableResult
    func writeText(_ text: String) throws -> Int {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw ClipboardWriteError.writeFailed
        }
        return pasteboard.changeCount
    }

    @discardableResult
    func writePNGData(_ data: Data) throws -> Int {
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            throw ClipboardWriteError.writeFailed
        }
        return pasteboard.changeCount
    }
}
