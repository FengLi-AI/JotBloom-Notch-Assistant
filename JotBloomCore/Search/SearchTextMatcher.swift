import Foundation

public enum SearchTextMatcher {
    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    public static func normalizedQuery(_ rawQuery: String) -> String? {
        let normalized = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    public static func contains(_ query: String, in text: String) -> Bool {
        firstMatch(of: query, in: text) != nil
    }

    public static func segments(
        in text: String,
        matching query: String,
        contextBefore: Int = 32,
        contextAfter: Int = 48
    ) -> [SearchTextSegment]? {
        guard !query.isEmpty,
              let firstMatch = firstMatch(of: query, in: text) else {
            return nil
        }

        let safeBefore = max(0, contextBefore)
        let safeAfter = max(0, contextAfter)
        let snippetStart = text.index(
            firstMatch.lowerBound,
            offsetBy: -safeBefore,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let snippetEnd = text.index(
            firstMatch.upperBound,
            offsetBy: safeAfter,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let snippet = String(text[snippetStart..<snippetEnd])

        var output: [SearchTextSegment] = []
        if snippetStart != text.startIndex {
            append("…", highlighted: false, to: &output)
        }

        appendHighlightedSegments(
            from: snippet,
            matching: query,
            to: &output
        )

        if snippetEnd != text.endIndex {
            append("…", highlighted: false, to: &output)
        }
        return output
    }

    private static func firstMatch(
        of query: String,
        in text: String,
        range: Range<String.Index>? = nil
    ) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        return text.range(
            of: query,
            options: [.caseInsensitive],
            range: range ?? text.startIndex..<text.endIndex,
            locale: comparisonLocale
        )
    }

    private static func appendHighlightedSegments(
        from snippet: String,
        matching query: String,
        to output: inout [SearchTextSegment]
    ) {
        var cursor = snippet.startIndex
        while cursor < snippet.endIndex,
              let match = firstMatch(
                of: query,
                in: snippet,
                range: cursor..<snippet.endIndex
              ),
              match.lowerBound < match.upperBound {
            if cursor < match.lowerBound {
                append(
                    String(snippet[cursor..<match.lowerBound]),
                    highlighted: false,
                    to: &output
                )
            }
            append(
                String(snippet[match]),
                highlighted: true,
                to: &output
            )
            cursor = match.upperBound
        }

        if cursor < snippet.endIndex {
            append(
                String(snippet[cursor..<snippet.endIndex]),
                highlighted: false,
                to: &output
            )
        }
    }

    private static func append(
        _ rawText: String,
        highlighted: Bool,
        to output: inout [SearchTextSegment]
    ) {
        let text = singleLine(rawText)
        guard !text.isEmpty else { return }
        if let last = output.last, last.isHighlighted == highlighted {
            output[output.count - 1] = SearchTextSegment(
                text: last.text + text,
                isHighlighted: highlighted
            )
        } else {
            output.append(
                SearchTextSegment(text: text, isHighlighted: highlighted)
            )
        }
    }

    private static func singleLine(_ value: String) -> String {
        value.map { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            } ? " " : String(character)
        }
        .joined()
    }
}
