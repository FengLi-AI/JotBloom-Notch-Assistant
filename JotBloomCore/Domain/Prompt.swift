import Foundation

public struct Prompt: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let content: String
    public let titleSource: ValueSource
    public let createdAtUTCms: Int64
    public let originKind: String
    public let sourceClipboardID: Int64?
    public let sourceApplicationName: String?
    public let sourceBundleIdentifier: String?
    public let submissionToken: String
    public let lifecycleToken: String
    public let titleRevision: Int64
    public var sortOrder: Int64 = 0
    public var isFavorite: Bool = false
}

public enum SaveTarget: Sendable { case prompt, inspiration }
public struct CrossSourceSaveResult: Equatable, Sendable {
    public let id: Int64
    public let created: Bool
}
public enum PromptError: Error, LocalizedError {
    case empty, tooLong, imageUnsupported, sourceMissing, missing, invalidTitle, duplicateInspiration
    public var errorDescription: String? {
        switch self {
        case .empty: return "内容为空，未保存。"
        case .tooLong: return "内容超过 100 万字符，未保存；原文仍保留。"
        case .imageUnsupported: return "暂不支持图片转存。"
        case .sourceMissing: return "原记录已不存在，请刷新后重试。"
        case .missing: return "这条提示词已不存在，请刷新后重试。"
        case .invalidTitle: return "标题不能为空。"
        case .duplicateInspiration: return "灵感库中已存在相同内容，未重复保存；修改仍保留。"
        }
    }
}

public enum PromptText {
    public static func validate(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PromptError.empty }
        guard text.count <= 1_000_000 else { throw PromptError.tooLong }
    }
    public static func fallback(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(12))
    }
}
