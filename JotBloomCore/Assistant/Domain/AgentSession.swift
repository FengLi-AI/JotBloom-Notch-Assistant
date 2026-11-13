import Foundation

extension ToolValue {
    public var object: [String: ToolValue] { if case .object(let value) = self { return value }; return [:] }
    public var array: [ToolValue] { if case .array(let value) = self { return value }; return [] }
    public var bool: Bool { self == .bool(true) }
    public subscript(_ key: String) -> ToolValue { object[key] ?? .null }
    public var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
}

public enum AssistantPermissionMode: String, CaseIterable, Sendable { case balanced, askAlways }
public enum AgentConnectionStatus: String, Sendable { case unchecked, notFound, signedOut, ready, unsupported, unavailable }
public struct AgentAvailability: Equatable, Sendable {
    public var status: AgentConnectionStatus
    public var ready: Bool { status == .ready }
    public var message: String
    public var path: String?
    public var version: String?
    public init(ready: Bool = false, message: String = "尚未检查 Codex", path: String? = nil, version: String? = nil, status: AgentConnectionStatus? = nil) {
        self.status = status ?? (ready ? .ready : .unchecked); self.message = message; self.path = path; self.version = version
    }
}
public enum AgentUserDecision: String, Sendable { case once, session, decline, answer }
public struct AgentInputQuestion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var options: [String]
}
public struct AgentApproval: Codable, Equatable, Sendable {
    public var requestID: ToolValue
    public var method: String
    public var parameters: ToolValue
    public var detail: String
    public var allowsSession: Bool
    public var questions: [AgentInputQuestion]
}
public struct AgentSession: Codable, Equatable, Sendable {
    public var threadID: String?
    public var turnID: String?
    public var stepID: Int64?
    public var active = false
    public var needsResume = false
    public var pending: AssistantRuntimeQuestion?
    public var response: ToolValue?
    public var lastReply = ""
    public var awaitingInterpretation = false
    public var changedFiles: [String] = []
    public var failure: String?
    public var workIdentity: String?
    public var supervision: AgentSupervisionState?
    public init() {}
}
public enum AgentRunOutcome: Sendable { case finished(String), waiting }
public enum AgentEvent: Sendable {
    case message(ToolValue)
    case closed
}

/// The coordinator and runtime depend on this interface, never JSON-RPC fields.
public protocol AgentConnector: Sendable {
    var events: AsyncStream<AgentEvent> { get }
    func connect(path: String) async throws -> AgentAvailability
    func create(scope: TaskScope) async throws -> String
    func resume(thread: String, scope: TaskScope) async throws
    func start(thread: String, scope: TaskScope, prompt: String) async throws -> String
    func steer(thread: String, turn: String, prompt: String) async throws
    func respond(id: ToolValue, result: ToolValue) async throws
    func interrupt(thread: String, turn: String) async
    func close() async
}

extension AgentConnector {
    public func steer(thread: String, turn: String, prompt: String) async throws {
        throw ExecutionError.unreadable("当前 Codex 连接不支持运行中补充，要求已保留。")
    }
}

public enum AssistantFolders {
    public static func validateWorking(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let denied = ["/", "/Volumes", "/Users", home]
        let protected = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/tmp", "/var", "/etc", "/dev", home + "/Library", home + "/.ssh", home + "/.codex"]
        var directory: ObjCBool = false
        guard !denied.contains(url.path), !protected.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw ExecutionError.denied("请选择具体项目文件夹，不能使用整个用户目录或系统目录。")
        }
        return url.path
    }
    public static func identity(_ path: String) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
    }
    public static func contains(_ path: String, root: String) -> Bool {
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath().path
        return candidate.hasPrefix(base + "/")
    }
}
