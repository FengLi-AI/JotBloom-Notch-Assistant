import Foundation

public enum InspirationCategory: String, CaseIterable, Codable, Sendable {
    case article = "文章类"
    case work = "作品类"
    case product = "产品类"
    case idea
}

public enum ValueSource: String, CaseIterable, Codable, Sendable {
    case ai
    case fallback
    case user
}

public enum InspirationSource: String, CaseIterable, Codable, Sendable {
    case manual
    case aiChat = "ai_chat"
}

public struct Inspiration: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let body: String
    public let category: InspirationCategory
    public let categorySource: ValueSource
    public let createdAtUTCms: Int64
    public let updatedAtUTCms: Int64
    public let source: InspirationSource
    public let originKind: String
    public let sourceClipboardID: Int64?
    public let sourceApplicationName: String?
    public let sourceBundleIdentifier: String?
    public let sortOrder: Int64

    public init(
        id: Int64,
        title: String,
        body: String,
        category: InspirationCategory,
        categorySource: ValueSource,
        createdAtUTCms: Int64,
        updatedAtUTCms: Int64,
        source: InspirationSource,
        originKind: String = "manual", sourceClipboardID: Int64? = nil,
        sourceApplicationName: String? = nil, sourceBundleIdentifier: String? = nil, sortOrder: Int64 = 0
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.category = category
        self.categorySource = categorySource
        self.createdAtUTCms = createdAtUTCms
        self.updatedAtUTCms = updatedAtUTCms
        self.source = source
        self.originKind = originKind; self.sourceClipboardID = sourceClipboardID
        self.sourceApplicationName = sourceApplicationName; self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sortOrder = sortOrder
    }

    public var updatedAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAtUTCms) / 1_000)
    }
}

public struct InspirationPageCursor: Equatable, Sendable {
    public let sortOrder: Int64?
    public let updatedAtUTCms: Int64
    public let id: Int64

    public init(updatedAtUTCms: Int64, id: Int64, sortOrder: Int64? = nil) {
        self.sortOrder = sortOrder
        self.updatedAtUTCms = updatedAtUTCms
        self.id = id
    }
}

public struct InspirationPage: Equatable, Sendable {
    public let items: [Inspiration]
    public let nextCursor: InspirationPageCursor?

    public init(
        items: [Inspiration],
        nextCursor: InspirationPageCursor?
    ) {
        self.items = items
        self.nextCursor = nextCursor
    }

    public var hasMore: Bool {
        nextCursor != nil
    }
}

public struct ParsedInspiration: Equatable, Sendable {
    public let title: String
    public let body: String
    public let originalText: String?

    public init(title: String, body: String, originalText: String? = nil) {
        self.title = title
        self.body = body
        self.originalText = originalText
    }
    public var completeText: String {
        originalText ?? (title.isEmpty || body.hasPrefix(title) ? body : body.isEmpty ? title : title + "\n" + body)
    }
}
