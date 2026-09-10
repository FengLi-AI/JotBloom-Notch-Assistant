import Foundation

public enum GlobalSearchScope: String, CaseIterable, Sendable {
    case all, clipboard, prompt, inspiration

    public var title: String {
        switch self {
        case .all: return "全部"
        case .clipboard: return "剪贴板"
        case .prompt: return "提示词"
        case .inspiration: return "灵感"
        }
    }

    public var source: SearchResultSource? {
        switch self {
        case .all: return nil
        case .clipboard: return .clipboard
        case .prompt: return .prompt
        case .inspiration: return .inspiration
        }
    }
}

public enum SearchResultSource: Int, CaseIterable, Hashable, Sendable {
    case clipboard
    case prompt
    case inspiration

    public var displayName: String {
        switch self {
        case .clipboard:
            return "剪贴板历史"
        case .prompt:
            return "提示词库"
        case .inspiration:
            return "灵感库"
        }
    }
}

public enum SearchLeadingKind: Equatable, Sendable {
    case text
    case link
    case inspiration
}

public struct SearchResultID: Hashable, Sendable {
    public let source: SearchResultSource
    public let recordID: Int64

    public init(source: SearchResultSource, recordID: Int64) {
        self.source = source
        self.recordID = recordID
    }
}

public struct SearchTextSegment: Equatable, Sendable {
    public let text: String
    public let isHighlighted: Bool

    public init(text: String, isHighlighted: Bool) {
        self.text = text
        self.isHighlighted = isHighlighted
    }
}

public struct GlobalSearchResult: Identifiable, Equatable, Sendable {
    public let id: SearchResultID
    public let source: SearchResultSource
    public let leadingKind: SearchLeadingKind
    public let segments: [SearchTextSegment]
    public let timestampUTCms: Int64
    public let accessibilityContext: String

    public init(
        id: SearchResultID,
        source: SearchResultSource,
        leadingKind: SearchLeadingKind,
        segments: [SearchTextSegment],
        timestampUTCms: Int64,
        accessibilityContext: String
    ) {
        self.id = id
        self.source = source
        self.leadingKind = leadingKind
        self.segments = segments
        self.timestampUTCms = timestampUTCms
        self.accessibilityContext = accessibilityContext
    }

    public var displayText: String {
        segments.map(\.text).joined()
    }
}

public struct GlobalSearchSnapshot: Equatable, Sendable {
    public let clipboard: [GlobalSearchResult]
    public let prompts: [GlobalSearchResult]
    public let inspirations: [GlobalSearchResult]

    public init(
        clipboard: [GlobalSearchResult],
        prompts: [GlobalSearchResult],
        inspirations: [GlobalSearchResult]
    ) {
        self.clipboard = clipboard
        self.prompts = prompts
        self.inspirations = inspirations
    }

    public static let empty = GlobalSearchSnapshot(
        clipboard: [],
        prompts: [],
        inspirations: []
    )

    public var allResults: [GlobalSearchResult] {
        clipboard + prompts + inspirations
    }

    public var isEmpty: Bool {
        clipboard.isEmpty && prompts.isEmpty && inspirations.isEmpty
    }

    public func results(for source: SearchResultSource) -> [GlobalSearchResult] {
        switch source {
        case .clipboard:
            return clipboard
        case .prompt:
            return prompts
        case .inspiration:
            return inspirations
        }
    }
}
