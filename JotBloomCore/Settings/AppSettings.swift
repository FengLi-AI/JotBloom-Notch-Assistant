import Foundation

public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String
    public static let standard = Shortcut(keyCode: 49, modifiers: 2048, label: "⌥Space")
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public var isValid: Bool {
        let allowed: UInt32 = 256 | 512 | 2048 | 4096
        guard modifiers & ~allowed == 0, modifiers & (256 | 2048 | 4096) != 0,
              keyCode <= 126, ![53,54,55,56,57,58,59,60,61,62,63].contains(keyCode),
              !label.isEmpty, label.count <= 40 else { return false }
        // Preserve quit, app switching, search, settings, editing and system session keys.
        if modifiers & 256 != 0, [0,3,6,7,8,9,12,13,17,18,19,20,21,22,23,35,43,48,49,51,124,123,125,126].contains(keyCode) { return false }
        return true
    }
}

public struct ModelConfiguration: Codable, Equatable, Sendable {
    public var baseURL = ""
    public var model = ""
    public init(baseURL: String = "", model: String = "") { self.baseURL = baseURL; self.model = model }
}

public enum ModelSlot: String, CaseIterable, Sendable { case main, auxiliary
    public var account: String { self == .main ? "main-api-key" : "aux-api-key" }
}

public struct AppSettings: Equatable, Sendable {
    public var shortcut = Shortcut.standard
    public var showMenuBarIcon = true
    public var monitoringEnabled = true
    public var maximumCount = 200
    public var maximumDays = 0
    public var maximumBytes: Int64 = 2_000_000_000
    public var onboardingSeen = false
    public var main = ModelConfiguration()
    public var auxiliary = ModelConfiguration()
    public var auxiliaryUsesMain = true
    public var inspirationAIEnabled = false
    public var chatSystemPrompt = ChatContext.system
    public init() {}
    public static let countOptions = [100, 200, 500, 1000, 5000, 0]
    public static let dayOptions = [7, 30, 90, 365, 0]
    public static let byteOptions: [Int64] = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, 0]
    public var retentionPolicy: ClipboardRetentionPolicy {
        ClipboardRetentionPolicy(maximumCount: maximumCount == 0 ? nil : maximumCount,
                                 maximumAgeMilliseconds: maximumDays == 0 ? nil : Int64(maximumDays) * 86_400_000,
                                 maximumBytes: maximumBytes == 0 ? nil : maximumBytes)
    }
    public func resolvedConfiguration(for slot: ModelSlot) -> (configuration: ModelConfiguration, credentialSlot: ModelSlot) {
        if slot == .main || auxiliary.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (main, .main) }
        return (ModelConfiguration(baseURL: auxiliaryUsesMain ? main.baseURL : auxiliary.baseURL, model: auxiliary.model), auxiliaryUsesMain ? .main : .auxiliary)
    }
}

public struct AppSettingsStore {
    private let defaults: UserDefaults
    private let key = "jotbloom.settings.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> AppSettings {
        let d = defaults.dictionary(forKey: key) ?? [:]
        var value = AppSettings()
        if let version = d["version"] as? Int, version != 1 { return value }
        if let data = d["shortcut"] as? Data, let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data), shortcut.isValid { value.shortcut = shortcut }
        value.showMenuBarIcon = d["showMenuBarIcon"] as? Bool ?? true
        value.monitoringEnabled = d["monitoringEnabled"] as? Bool ?? true
        value.onboardingSeen = d["onboardingSeen"] as? Bool ?? false
        if let count = d["maximumCount"] as? Int, AppSettings.countOptions.contains(count) { value.maximumCount = count }
        if let days = d["maximumDays"] as? Int, AppSettings.dayOptions.contains(days) { value.maximumDays = days }
        if let bytes = (d["maximumBytes"] as? NSNumber)?.int64Value, AppSettings.byteOptions.contains(bytes) { value.maximumBytes = bytes }
        value.main = ModelConfiguration(baseURL: d["mainURL"] as? String ?? "", model: d["mainModel"] as? String ?? "")
        value.auxiliary = ModelConfiguration(baseURL: d["auxURL"] as? String ?? "", model: d["auxModel"] as? String ?? "")
        value.auxiliaryUsesMain = d["auxiliaryUsesMain"] as? Bool ?? true
        value.inspirationAIEnabled = d["inspirationAIEnabled"] as? Bool ?? false
        if let text = d["chatSystemPrompt"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000 { value.chatSystemPrompt = text }
        return value
    }
    public func save(_ value: AppSettings) {
        defaults.set(["version": 1, "shortcut": (try? JSONEncoder().encode(value.shortcut)) ?? Data(),
                      "showMenuBarIcon": value.showMenuBarIcon, "monitoringEnabled": value.monitoringEnabled,
                      "onboardingSeen": value.onboardingSeen, "maximumCount": value.maximumCount,
                      "maximumDays": value.maximumDays, "maximumBytes": value.maximumBytes,
                      "mainURL": value.main.baseURL, "mainModel": value.main.model,
                      "auxURL": value.auxiliary.baseURL, "auxModel": value.auxiliary.model,
                      "auxiliaryUsesMain": value.auxiliaryUsesMain, "inspirationAIEnabled": value.inspirationAIEnabled,
                      "chatSystemPrompt": value.chatSystemPrompt] as [String: Any], forKey: key)
    }
}

public enum SettingsError: Error, LocalizedError, Equatable {
    case invalidURL, missingModel, missingKey, credentialDenied, credentialLocked, credentialCancelled, credentialUnavailable, invalidShortcut
    case maintenance, invalidDirectory, unavailableDirectory, migrationFailed, responseInvalid, responseTooLarge
    case responseTruncated, reasoningOnlyResponse, emptyResponse
    case http(Int), network, timeout, cancelled
    public var isCredentialIssue: Bool {
        switch self {
        case .missingKey, .credentialDenied, .credentialLocked, .credentialCancelled, .credentialUnavailable: return true
        default: return false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTPS 接口地址；只有本机回环地址允许 HTTP，不支持用户名、查询参数和片段。"
        case .missingModel: return "请填写模型名称。"
        case .missingKey: return "尚未配置 API Key，本地记录功能仍可正常使用。"
        case .credentialDenied: return "钥匙串访问未获允许，请解锁或重新授权后重试。"
        case .credentialLocked: return "钥匙串当前锁定或不允许交互，请解锁后重试。"
        case .credentialCancelled: return "已取消钥匙串授权，原有密钥保持不变。"
        case .credentialUnavailable: return "钥匙串暂不可用，请检查系统状态后重试。"
        case .invalidShortcut: return "请使用包含 ⌥、⌃ 或 ⌘ 的有效组合，避开系统及编辑快捷键。"
        case .maintenance: return "数据维护中，请稍后重试。"
        case .invalidDirectory: return "请选择本机可写且不包含现有数据的独立位置。"
        case .unavailableDirectory: return "数据位置不可用。请连接原磁盘或重新定位原数据目录，不能创建空库替代。"
        case .migrationFailed: return "迁移未完成，源数据仍保留；请检查空间、权限和图片文件后重试。"
        case .responseInvalid: return "服务返回的内容不是有效的模型回复，请检查地址、模型与兼容协议。"
        case .responseTruncated: return "模型回复达到输出上限，尚未完整生成；请使用非思考模式或更适合短任务的模型。"
        case .reasoningOnlyResponse: return "模型只返回了思考内容，没有正式回答；请检查模型的思考模式设置。"
        case .emptyResponse: return "服务返回了空回答，请稍后重试或检查模型配置。"
        case .responseTooLarge: return "测试响应过大，已停止接收。"
        case .http(let code): return code == 401 || code == 403 ? "认证失败，请检查 API Key 和模型权限。" : code == 429 ? "请求受限，请稍后重试。" : "服务返回 HTTP \(code)，请检查接口配置。"
        case .network: return "无法连接服务，请检查网络和地址。"
        case .timeout: return "连接测试超时，请稍后重试。"
        case .cancelled: return "连接测试已取消。"
        }
    }
}

public enum ModelEndpoint {
    public static func normalize(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/chat/completions") { value.removeLast("/chat/completions".count) }
        while value.hasSuffix("/") { value.removeLast() }
        guard let c = URLComponents(string: value), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.url != nil,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else { throw SettingsError.invalidURL }
        return value
    }
    public static func maskedKey(_ key: String) -> String { key.count > 4 ? "••••" + key.suffix(4) : "••••" }
}

public protocol CredentialStoring: Sendable {
    func read(_ slot: ModelSlot) async throws -> String?
    func readWithoutInteraction(_ slot: ModelSlot) async throws -> String?
    /// Only a deliberate credential-recovery action may call this method.
    func authorize(_ slot: ModelSlot) async throws -> String?
    func write(_ secret: String, slot: ModelSlot) async throws
    func remove(_ slot: ModelSlot) async throws
}

public extension CredentialStoring {
    // Unknown adapters fail closed, never silently call the interactive method.
    func readWithoutInteraction(_ slot: ModelSlot) async throws -> String? { throw SettingsError.credentialUnavailable }
    func authorize(_ slot: ModelSlot) async throws -> String? { throw SettingsError.credentialUnavailable }
}

public actor MemoryCredentialStore: CredentialStoring {
    private var values: [String: String] = [:]
    public init() {}
    public func read(_ slot: ModelSlot) -> String? { values[slot.rawValue] }
    public func readWithoutInteraction(_ slot: ModelSlot) async throws -> String? { values[slot.rawValue] }
    public func write(_ secret: String, slot: ModelSlot) { values[slot.rawValue] = secret }
    public func remove(_ slot: ModelSlot) { values.removeValue(forKey: slot.rawValue) }
}
