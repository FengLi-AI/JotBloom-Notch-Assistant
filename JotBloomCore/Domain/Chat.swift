import Foundation

public struct ChatSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let timestamp: Int64
    public let isCurrent: Bool
}

public enum ChatStatus: String, Sendable {
    case waiting, streaming, complete, stopped, failed, interrupted, length
    public var isActive: Bool { self == .waiting || self == .streaming }
}

public struct ChatTurn: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let session: String
    public let token: String
    public var attempt: String
    public let user: String
    public var answer: String
    public let timestamp: Int64
    public var status: ChatStatus
    public var errorCode: String?
}

public struct ChatPage: Sendable {
    public let turns: [ChatTurn]
    public let hasMore: Bool
}

public enum ChatError: String, Error, LocalizedError, Sendable {
    case busy, stale, tooLong, malformed, incomplete, empty, overflow, storage, missingConfiguration
    public var errorDescription: String? {
        switch self {
        case .busy: return "请先等待当前回复结束，或点击停止。"
        case .stale: return "当前对话已改变，请重新发送。"
        case .tooLong: return "输入或最近三轮内容太长，请缩短输入或开始新对话。"
        case .malformed: return "服务未返回支持的流式文本，请检查接口和模型。"
        case .incomplete: return "回复中途断开，已收到的文字保留，可重试。"
        case .empty: return "模型没有返回正式回答，请检查模型配置后重试。"
        case .overflow: return "回复超过安全长度，已停止接收。"
        case .storage: return "对话未能保存到磁盘，请重试；当前内容仍保留。"
        case .missingConfiguration: return "配置 AI 接口后可开始对话。"
        }
    }
}
