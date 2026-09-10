import Foundation

public enum InspirationTextParser {
    public static func parse(_ text: String) -> ParsedInspiration? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let lines = text.components(separatedBy: "\n")
        let firstLine = lines.first ?? ""
        let title = String(firstLine.prefix(30))
        let body = lines.count == 1
            ? text
            : lines.dropFirst().joined(separator: "\n")

        return ParsedInspiration(title: title, body: body, originalText: text)
    }
}
