import Foundation

public enum ToolValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([ToolValue]), object([String: ToolValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([ToolValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ToolValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var text: String? { if case .string(let v) = self { return v }; return nil }
    public var strings: [String]? {
        guard case .array(let values) = self, values.allSatisfy({ $0.text != nil }) else { return nil }
        return values.compactMap(\.text)
    }
}
public enum ToolRisk: String, Sendable { case direct, notify, ask }
public enum AssistantToolName: String, Codable, CaseIterable, Sendable {
    case searchMaterials = "search_materials", readMaterial = "read_material", readUserFile = "read_user_file"
    case readURL = "read_url", writeResult = "write_result_file", readResult = "read_result_file", listResults = "list_result_files"
    case delegateToCodex = "delegate_to_codex", continueCodex = "continue_codex"
    case setReminder = "set_reminder", saveInspiration = "save_inspiration", askUser = "ask_user", requestScope = "request_scope", finish
    public var risk: ToolRisk {
        switch self { case .setReminder, .saveInspiration: return .notify; case .askUser, .requestScope: return .ask; default: return .direct }
    }
    public var progress: String {
        switch self {
        case .delegateToCodex: return "派给 Codex 推进任务"
        case .continueCodex: return "继续原 Codex 会话"
        case .searchMaterials: return "查找相关灵感和提示词"
        case .readMaterial: return "读取已允许的资料"
        case .readUserFile: return "读取你提供的文件"
        case .readURL: return "读取你提供的网页"
        case .writeResult: return "写入任务结果文件"
        case .readResult: return "检查已写好的结果"
        case .listResults: return "检查结果文件列表"
        case .setReminder: return "调整这个任务的提醒"
        case .saveInspiration: return "存成一条新灵感"
        case .askUser: return "有件事需要你补充"
        case .requestScope: return "需要你确认是否扩大范围"
        case .finish: return "核对结果并汇报"
        }
    }
}
public struct AssistantStepAction: Codable, Equatable, Sendable {
    public var progress: String
    public let tool: AssistantToolName
    public let args: [String: ToolValue]
    private enum CodingKeys: String, CodingKey { case progress, tool, args }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tool = try values.decode(AssistantToolName.self, forKey: .tool)
        args = try values.decode([String: ToolValue].self, forKey: .args)
        progress = try values.decodeIfPresent(String.self, forKey: .progress) ?? ""
    }
    public init(tool: AssistantToolName, args: [String: ToolValue] = [:], progress: String = "") {
        self.tool = tool; self.args = args; self.progress = progress.isEmpty ? tool.progress : progress
    }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return tool.rawValue + String(decoding: (try? encoder.encode(args)) ?? Data(), as: UTF8.self)
    }
}
public enum ExecutionError: Error, LocalizedError, Equatable {
    case invalid(String), denied(String), unreadable(String), changedDirectory
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .denied(let s), .unreadable(let s): return s
        case .changedDirectory: return "结果文件夹已被替换或移动，请检查后重新交办，已有文件保留。"
        }
    }
}
public enum StepValidator {
    public static func parse(_ text: String) throws -> AssistantStepAction {
        var action: AssistantStepAction
        do {
            let data = TaskBriefValidator.json(text)
            do { action = try JSONDecoder().decode(AssistantStepAction.self, from: data) }
            catch { action = try JSONDecoder().decode(AssistantStepAction.self, from: escapingLiteralWhitespace(data)) }
        }
        catch { throw ExecutionError.invalid("需要合法 JSON，包含 progress、工具箱内的 tool 和对象 args。") }
        try validate(action)
        let keys: Set<String>
        switch action.tool {
        case .delegateToCodex, .continueCodex: keys = ["instructions", "answersCodexQuestion", "answerEvidence"]
        case .searchMaterials: keys = ["keywords"]
        case .readMaterial, .readUserFile: keys = ["id"]
        case .readURL: keys = ["url"]
        case .writeResult: keys = ["name", "content", "mode"]
        case .readResult: keys = ["name"]
        case .listResults: keys = []
        case .setReminder: keys = ["time", "id"]
        case .saveInspiration: keys = ["content"]
        case .askUser: keys = ["question"]
        case .requestScope: keys = ["kind", "reason", "candidateSetId"]
        case .finish: keys = ["status", "summary"]
        }
        // Unknown fields have no effect, including on repeat detection.
        action = AssistantStepAction(tool: action.tool, args: action.args.filter { keys.contains($0.key) }, progress: action.progress)
        if action.progress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action.progress.count > 40 { action.progress = action.tool.progress }
        return action
    }
    /// Some models emit literal Markdown newlines inside JSON strings. Escape
    /// only those whitespace bytes without changing values, keys or structure.
    /// Malformed quotes, escapes, extra objects and invalid actions still fail.
    private static func escapingLiteralWhitespace(_ data: Data) -> Data {
        var result = Data(); result.reserveCapacity(data.count)
        var inString = false, escaped = false
        let escapes: [UInt8: UInt8] = [10: 110, 13: 114, 9: 116]
        for byte in data {
            if inString && !escaped, let replacement = escapes[byte] {
                result.append(92); result.append(replacement); continue
            }
            result.append(byte)
            if escaped { escaped = false }
            else if inString && byte == 92 { escaped = true }
            else if byte == 34 { inString.toggle() }
        }
        return result
    }
    public static func validate(_ action: AssistantStepAction) throws {
        func text(_ key: String, max: Int = 8000, empty: Bool = false) throws -> String {
            guard let s = action.args[key]?.text, (empty || !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), s.count <= max else { throw ExecutionError.invalid("参数 \(key) 必须是非空文字，最多 \(max) 字。") }; return s
        }
        switch action.tool {
        case .delegateToCodex, .continueCodex:
            _ = try text("instructions", max: 8000)
            if let flag = action.args["answersCodexQuestion"], flag != .bool(true) && flag != .bool(false) { throw ExecutionError.invalid("answersCodexQuestion 必须是布尔值。") }
        case .searchMaterials:
            guard let words = action.args["keywords"]?.strings, !words.isEmpty, words.count <= 5, words.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else { throw ExecutionError.invalid("keywords 需要 1 到 5 个短关键词。") }
        case .readMaterial, .readUserFile: _ = try text("id", max: 4096)
        case .readURL: _ = try text("url", max: 4096)
        case .writeResult:
            try AssistantResultFiles.validateName(text("name", max: 180)); _ = try text("content", max: 100_000, empty: true)
            guard ["create", "overwrite", "append"].contains(try text("mode", max: 20)) else { throw ExecutionError.invalid("mode 只能为 create、overwrite 或 append。") }
        case .readResult: try AssistantResultFiles.validateName(text("name", max: 180), allTypes: true)
        case .listResults: break
        case .saveInspiration: _ = try text("content", max: 20_000)
        case .setReminder:
            let time = try text("time", max: 16)
            guard AssistantDates.parse(time, timeZone: .current) != nil else { throw ExecutionError.invalid("time 使用 yyyy-MM-ddTHH:mm。") }
            if action.args["id"] != nil { _ = try text("id", max: 100) }
        case .askUser: _ = try text("question", max: 500)
        case .requestScope:
            guard ["materials", "network", "codex"].contains(try text("kind", max: 30)) else { throw ExecutionError.invalid("范围申请类型不支持。") }
            _ = try text("reason", max: 500)
            if action.args["kind"]?.text == "materials" { _ = try text("candidateSetId", max: 100) }
        case .finish:
            _ = try text("summary", max: 2000)
            guard ["completed", "failed"].contains(try text("status", max: 20)) else { throw ExecutionError.invalid("完成状态只能是 completed 或 failed。") }
        }
    }
}
public enum PermissionDecision: Equatable, Sendable { case allow, allowAndRecord, askUser, deny(String) }
public enum PermissionGate {
    public static func decide(_ action: AssistantStepAction, scope: TaskScope, state: AssistantExecutionState) -> PermissionDecision {
        let id = action.args["id"]?.text ?? ""
        switch action.tool {
        case .delegateToCodex, .continueCodex:
            guard scope.allowCodex else { return .deny("尚未允许派给 Codex，请先申请 codex 范围。") }
            if action.args["answersCodexQuestion"] == .bool(true), scope.permissionMode == AssistantPermissionMode.askAlways.rawValue { return .deny("每次都问我模式下，Codex 的追问必须通过 ask_user 交给用户，不能代答。") }
        case .readMaterial:
            guard scope.materials.contains(where: { $0.id == id && $0.kind != .file }) || (scope.autoFind && state.discovered.contains(where: { $0.id == id && [.inspiration, .prompt].contains($0.kind) })) else { return .deny("这条资料不在允许范围内，请先查找并申请资料。") }
        case .readUserFile:
            guard scope.materials.contains(where: { $0.id == id && $0.kind == .file }) else { return .deny("只能读取用户勾选或拖入并确认的文件。") }
        case .readURL:
            guard state.userURLs.contains(action.args["url"]?.text ?? "") else { return .deny("只能读取用户给出的完整地址，不能拼接参数或读取页面中的链接。") }
            guard scope.allowNetwork else { return .deny("联网尚未允许，请用 request_scope 申请。") }
        case .requestScope:
            let kind = action.args["kind"]?.text ?? ""
            if state.deniedScopes.contains(kind) { return .deny("用户已拒绝这类申请，请用现有范围继续；不能重复申请。") }
            if kind == "materials" {
                guard let candidates = state.candidates[action.args["candidateSetId"]?.text ?? ""],
                      candidates.contains(where: { candidate in !(state.declinedMaterials ?? []).contains(candidate.id) && !scope.materials.contains(where: { $0.id == candidate.id }) }) else { return .deny("候选集合已失效或已由用户处理；未选资料不重复申请，请用现有范围继续。") }
            }
            return .askUser
        case .askUser: return .askUser
        case .setReminder, .saveInspiration: return .allowAndRecord
        default: break
        }
        return .allow
    }
}
public struct AssistantExecutionState: Codable, Equatable, Sendable {
    public var calls = 0
    public var estimatedTokens = 0
    public var stepLimit = 40
    public var tokenLimit = 600_000
    public var materialCharacters = 0
    public var discovered: [AssistantAttachment] = []
    public var candidates: [String: [AssistantAttachment]] = [:]
    public var deniedScopes: Set<String> = []
    // Optional for compatibility with runtime rows written before this field existed.
    public var declinedMaterials: Set<String>? = nil
    public var userURLs: [String] = []
    public var supplements: [String] = []
    public var codexUserAnswer: CodexUserAnswer? = nil
    public var lastFingerprint = ""
    public var repeats = 0
    public var directoryIdentity: String?
    public var activeSeconds: Double = 0
    public var timeLimitSeconds: Double = 3600
    public init() {}
}
public struct AssistantExecutionStep: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let action: AssistantStepAction
    public let state: String
    public let result: String
    public let undo: String?
    public let undone: Bool
}
public struct AssistantRuntimeQuestion: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var kind: String
    public var text: String
    public var scopeKind: String?
    public var candidates: [AssistantAttachment] = []
    public var stepID: Int64?
    public var agent: AgentApproval? = nil
    public var codexThreadID: String? = nil
}
public struct CodexUserAnswer: Codable, Equatable, Sendable {
    public var threadID: String
    public var text: String
}
public struct AssistantMaterialUsage: Identifiable, Equatable, Sendable {
    public var id: String { attachment.id }
    public let attachment: AssistantAttachment
    public let selected: Bool
    public let sent: Bool
}
public struct AssistantResultFile: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let bytes: Int64
    public let url: URL
}
