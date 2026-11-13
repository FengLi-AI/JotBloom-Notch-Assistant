import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case received, understanding, needsInfo, planReady, scheduled, queued, running
    case waitingUser, interrupted, completed, failed, cancelled
    public var title: String {
        switch self {
        case .received: return "收到了"
        case .understanding: return "正在理解"
        case .needsInfo: return "需要补充"
        case .planReady: return "等你确认"
        case .scheduled: return "已安排"
        case .queued: return "排队中"
        case .running: return "执行中"
        case .waitingUser: return "等你回答"
        case .interrupted: return "已中断"
        case .completed: return "已完成"
        case .failed: return "没做成"
        case .cancelled: return "已取消"
        }
    }
    public var group: AssistantTaskGroup? {
        switch self {
        case .needsInfo, .planReady, .waitingUser, .interrupted: return .attention
        case .received, .understanding, .queued, .running: return .active
        case .scheduled: return .scheduled
        case .completed, .failed: return .finished
        case .cancelled: return nil
        }
    }
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

public enum AssistantTaskGroup: String, CaseIterable, Identifiable {
    case attention = "等你处理", active = "进行中", scheduled = "已安排", finished = "已完成"
    public var id: String { rawValue }
}

public enum AssistantSource: String, Codable, Sendable { case notchText, notchFiles, chat }
public enum AssistantMaterialKind: String, Codable, Sendable { case inspiration, prompt, file, chat }

public struct AssistantAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { kind.rawValue + ":" + reference }
    public let kind: AssistantMaterialKind
    public let reference: String
    public let title: String
    public init(kind: AssistantMaterialKind, reference: String, title: String) {
        self.kind = kind; self.reference = reference; self.title = title
    }
    public static func file(_ url: URL) -> Self {
        .init(kind: .file, reference: url.standardizedFileURL.path, title: url.lastPathComponent)
    }
}

public struct AssistantTask: Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public let rawInput: String
    public let source: AssistantSource
    public let chatSession: String?
    public let chatTurn: String?
    public var status: TaskStatus
    public var errorCode: String?
    public var resultSummary: String?
    public var outputDirectory: String?
    public var dueAt: Int64?
    public let createdAt: Int64
    public var updatedAt: Int64
    public var completedAt: Int64?
    public var brief: TaskBrief? = nil
    public var plan: AssistantPlan? = nil
    public var scope: TaskScope? = nil
}

public struct AssistantTaskEvent: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let taskID: String
    public let kind: String
    public let text: String
    public let createdAt: Int64
}

/// A small tombstone survives task deletion; the original chat message is never rewritten.
public struct AssistantTaskLink: Equatable, Sendable {
    public let turn: String
    public let taskID: String?
    public let title: String
}

public enum AssistantError: Error, LocalizedError, Equatable {
    case empty, missing, invalidTransition, stale, unavailable
    public var errorDescription: String? {
        switch self {
        case .empty: return "请先写一件事，或添加资料。"
        case .missing: return "这件事已删除。"
        case .invalidTransition: return "任务状态已变化，请刷新后重试。"
        case .stale: return "当前对话已变化，内容仍保留，请重试。"
        case .unavailable: return "暂时无法保存任务，内容仍保留，请重试。"
        }
    }
}
