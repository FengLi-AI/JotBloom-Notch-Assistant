import Foundation

public struct PromptTitleService: Sendable {
    public static let systemPrompt = """
    你是一个标题生成器。用户会给你一段提示词内容，你只需要输出一个 5 到 10 个字的中文标题，概括这段提示词的用途。

    规则：
    - 只输出标题本身，不要输出引号、句号、解释、前后缀
    - 严格控制在 5 到 10 个字
    - 用名词短语，不要用完整句子
    - 不要以"关于"、"如何"开头
    """
    private let transport: any ConnectionTransport
    public init(transport: any ConnectionTransport = URLSessionConnectionTransport()) { self.transport = transport }
    public func title(content: String, configuration: ModelConfiguration, key: String) async throws -> String {
        let base = try ModelEndpoint.normalize(configuration.baseURL)
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SettingsError.missingModel }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !key.contains("\n"), !key.contains("\r") else { throw SettingsError.missingKey }
        var request = URLRequest(url: URL(string: base + "/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["model": model, "stream": false, "temperature": 0.3,
            "messages": [["role": "system", "content": Self.systemPrompt], ["role": "user", "content": String(content.prefix(2000))]]]
        ShortModelTask.applyOptions(to: &body, baseURL: base, model: model)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try Task.checkCancellation()
        let (data, status) = try await transport.send(request)
        try Task.checkCancellation()
        guard (200...299).contains(status) else { throw SettingsError.http(status) }
        guard data.count <= 262_144 else { throw SettingsError.responseTooLarge }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SettingsError.responseInvalid }
        let text = try ShortModelTask.assistantText(in: json)
        guard let title = Self.parse(text) else { throw SettingsError.responseInvalid }
        return title
    }
    public static func parse(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Do not flatten multiline output into a plausible-looking title.
        guard !value.contains(where: \.isNewline) else { return nil }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？；;，,"))
        for (left, right) in [("\"", "\""), ("“", "”"), ("'", "'"), ("「", "」")] {
            if value.hasPrefix(left), value.hasSuffix(right), value.count >= 2 { value.removeFirst(); value.removeLast(); break }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？；;，,"))
        guard !value.isEmpty, value.count <= 20 else { return nil }
        return String(value.prefix(10))
    }
}

@MainActor
public final class PromptTitleCoordinator {
    public var additionalJob: ((Int64) async -> Void)?
    @discardableResult public func enqueueInspiration(_ id: Int64) -> Bool {
        guard id > 0, pending.count < 32 else { return false }
        if scheduled.contains(-id) { return true }
        enqueue(-id); return true
    }
    public var onChange: (() -> Void)?
    public var onFailure: ((Int64, SettingsError) -> Void)?
    public private(set) var activeCount = 0
    public var pendingCount: Int { pending.count }
    private let store: JotBloomStore
    private let credentials: any CredentialStoring
    private let settings: () -> AppSettings
    private let service: PromptTitleService
    private var generation = 0
    private var pending: [Int64] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var scheduled: Set<Int64> = []
    public init(store: JotBloomStore, credentials: any CredentialStoring, settings: @escaping () -> AppSettings, service: PromptTitleService = PromptTitleService()) {
        self.store = store; self.credentials = credentials; self.settings = settings; self.service = service
    }
    deinit { for task in tasks.values { task.cancel() } }
    public func enqueue(_ id: Int64) {
        guard pending.count < 32, scheduled.insert(id).inserted else { return }
        pending.append(id); pump()
    }
    public func invalidate() {
        generation += 1; pending.removeAll(); scheduled.removeAll()
        for task in tasks.values { task.cancel() }
        // Keep in-flight slots occupied until their awaited operations actually finish.
    }
    public func drain() async {
        invalidate()
        let running = Array(tasks.values)
        for task in running { await task.value }
    }
    private func pump() {
        while tasks.count < 2, !pending.isEmpty {
            let id = pending.removeFirst(), token = UUID(), expected = generation
            let config = settings().resolvedConfiguration(for: .auxiliary)
            let task = Task { [weak self] in
                guard let self else { return }
                defer { tasks.removeValue(forKey: token); activeCount = tasks.count; scheduled.remove(id); pump() }
                if id < 0 { await additionalJob?(-id); return }
                do {
                    // An unconfigured model is an intentional local-only workflow.
                    guard !config.configuration.baseURL.isEmpty, !config.configuration.model.isEmpty else { return }
                    _ = try ModelEndpoint.normalize(config.configuration.baseURL)
                    guard !config.configuration.model.isEmpty, let prompt = try await store.prompt(id: id), prompt.titleSource == .fallback else { return }
                    try Task.checkCancellation()
                    guard expected == generation else { return }
                    guard let key = try await credentials.readWithoutInteraction(config.credentialSlot) else { throw SettingsError.missingKey }
                    try Task.checkCancellation()
                    guard expected == generation else { return }
                    let title = try await service.title(content: String(prompt.content.prefix(2000)), configuration: config.configuration, key: key)
                    try Task.checkCancellation()
                    guard expected == generation else { return }
                    // Synchronous CAS cannot yield between generation validation and commit.
                    if try store.applyPromptTitleSynchronously(title, expected: prompt) { onChange?() }
                } catch {
                    guard !Task.isCancelled, expected == generation,
                          let current = try? await store.prompt(id: id), current.titleSource == .fallback,
                          !Task.isCancelled, expected == generation else { return }
                    let reason: SettingsError
                    if let known = error as? SettingsError { reason = known }
                    else if let network = error as? URLError { reason = network.code == .timedOut ? .timeout : .network }
                    else { reason = .responseInvalid }
                    onFailure?(id, reason)
                }
            }
            tasks[token] = task; activeCount = tasks.count
        }
    }
}
