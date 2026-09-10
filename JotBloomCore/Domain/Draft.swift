import Foundation

public enum DraftKind: String, CaseIterable, Codable, Sendable {
    case inspiration
    case aiChat = "ai_chat"
}

public struct Draft: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let kind: DraftKind
    public let content: String
    public let updatedAtUTCms: Int64

    public init(id: Int64, kind: DraftKind, content: String, updatedAtUTCms: Int64) {
        self.id = id
        self.kind = kind
        self.content = content
        self.updatedAtUTCms = updatedAtUTCms
    }
}
