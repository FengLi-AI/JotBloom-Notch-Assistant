import Foundation

public enum ClipboardContentClassifier {
    public static let maximumTextCharacterCount = 1_000_000
    public static let maximumLinkCharacterCount = 2_048

    public static func classify(_ text: String) -> ClipboardContentType? {
        guard !text.isEmpty, text.count <= maximumTextCharacterCount else {
            return nil
        }
        return isLink(text) ? .link : .text
    }

    public static func isLink(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.count <= maximumLinkCharacterCount,
              !candidate.contains(where: { $0.isWhitespace }),
              let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return true
    }

    public static func utf8ByteCount(of text: String) -> Int64 {
        Int64(text.lengthOfBytes(using: .utf8))
    }
}
