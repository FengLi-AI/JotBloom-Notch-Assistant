import Foundation

public actor CodexConnector: AgentConnector {
    private let transport = AgentRPCTransport()
    public nonisolated var events: AsyncStream<AgentEvent> { transport.events }
    private var connectedPath: String?
    public init() {}
    public static func candidates(custom: String?) -> [String] {
        [custom, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path].compactMap { $0 }.filter { !$0.isEmpty }
    }
    public static func discover(custom: String? = nil) async -> AgentAvailability {
        for path in candidates(custom: custom) where FileManager.default.isExecutableFile(atPath: path) {
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: path); child.arguments = ["--version"]
            child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
            do { try child.run() } catch { continue }
            for _ in 0..<30 { if !child.isRunning { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            if child.isRunning { child.terminate(); if child.isRunning { kill(child.processIdentifier, SIGKILL) }; continue }
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile().prefix(1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard child.terminationStatus == 0, text.hasPrefix("codex-cli ") else { continue }
            return .init(ready: false, message: "已找到 Codex，正在检查连接", path: path, version: text)
        }
        return .init(message: "未找到 Codex。请安装 Codex，或选择本机 codex 可执行文件；整理和提醒仍可使用。", status: .notFound)
    }
    public func connect(path: String) async throws -> AgentAvailability {
        let alive = await transport.isRunning()
        if connectedPath != path || !alive {
            if connectedPath != nil { await close() }
            try await transport.launch(path)
            do {
                let response = try await transport.request("initialize", .object(["clientInfo": .object(["name": .string("jotbloom"), "title": .string("萌生助手"), "version": .string("1.0")])]))
                // Ignore extra metadata; require the protocol identity we use to
                // distinguish an app-server handshake from an unrelated response.
                guard let identity = response["userAgent"].text, !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return await unsupported(path: path, reason: "握手返回缺少有效的 userAgent。")
                }
                try await transport.notify("initialized")
            } catch is CancellationError { await close(); throw CancellationError() }
            catch { return await unsupported(path: path, reason: "未能完成 app-server 握手。") }
            connectedPath = path
        }
        let account: ToolValue
        do { account = try await transport.request("account/read", .object(["refreshToken": .bool(false)])) }
        catch AgentRPCError.methodNotFound { return await unsupported(path: path, reason: "缺少必需的 account/read 接口。") }
        guard case .bool = account["requiresOpenaiAuth"], account["account"] == .null || account["account"]["type"].text?.isEmpty == false else {
            return await unsupported(path: path, reason: "账号状态返回缺少或包含无效的关键字段。")
        }
        let ready = account["account"] != .null || account["requiresOpenaiAuth"] == .bool(false)
        return .init(ready: ready, message: ready ? "Codex 已连接，可派任务" : "请先在 Codex 中登录，再点重新检测。", path: path, status: ready ? .ready : .signedOut)
    }
    private func unsupported(path: String, reason: String) async -> AgentAvailability {
        await close()
        return .init(message: "Codex 版本不支持：" + reason, path: path, status: .unsupported)
    }
    public static func sandbox(_ scope: TaskScope) -> ToolValue {
        .object(["type": .string("workspaceWrite"), "writableRoots": .array(([scope.outputDirectory] + [scope.workingDirectory].compactMap { $0 }).map(ToolValue.string)), "networkAccess": .bool(scope.allowNetwork), "excludeSlashTmp": .bool(true), "excludeTmpdirEnvVar": .bool(true)])
    }
    public static func sessionConfiguration(_ scope: TaskScope) -> ToolValue {
        // A task must not inherit an app/plugin's global auto-approval rules or
        // network channel. This changes only this thread's effective config.
        .object(["web_search": .string(scope.allowNetwork ? "live" : "disabled"),
                 "features.apps": .bool(false), "plugins._default.enabled": .bool(false)])
    }
    static func isolatedConfiguration(_ scope: TaskScope, servers: [ToolValue]) throws -> ToolValue {
        var config = sessionConfiguration(scope).object
        for server in servers {
            let plugin = server["pluginId"].text
            guard let name = plugin ?? server["name"].text, !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || "_-@/".contains($0) }) else {
                throw ExecutionError.denied("Codex 外部工具名称无法安全隔离，已停止派活。萌生不会改动全局设置。")
            }
            // app-server config keys are dotted paths, not quoted TOML paths.
            // Disable plugin entries at their source; synthesizing an MCP entry
            // for a plugin would lose its transport and invalidate the config.
            config[(plugin == nil ? "mcp_servers." : "plugins.") + name + ".enabled"] = .bool(false)
        }
        return .object(config)
    }
    private func toolInventory(thread: String) async throws -> [ToolValue] {
        var cursor: String?
        var servers: [ToolValue] = []
        for _ in 0..<20 {
            var args: [String: ToolValue] = ["threadId": .string(thread), "detail": .string("toolsAndAuthOnly"), "limit": .number(100)]
            if let cursor { args["cursor"] = .string(cursor) }
            let result = try await transport.request("mcpServerStatus/list", .object(args))
            guard case .array(let data) = result["data"] else { throw ExecutionError.invalid("Codex 未返回有效的工具清单，已停止派活。") }
            servers.append(contentsOf: data)
            cursor = result["nextCursor"].text
            if cursor == nil { return servers }
        }
        throw ExecutionError.denied("Codex 工具清单未能完整检查，已停止派活。")
    }
    private func verifyIsolatedTools(thread: String) async throws {
        guard try await toolInventory(thread: thread).allSatisfy({ $0["runtimeStatus"].text == "disabled" && $0["tools"].object.isEmpty }) else {
            throw ExecutionError.denied("当前 Codex 配置仍启用了外部工具，无法保证本任务的批准和联网范围，已停止派活。萌生不会改动你的全局设置。")
        }
    }
    private func parameters(_ scope: TaskScope) -> [String: ToolValue] {
        ["config": Self.sessionConfiguration(scope), "cwd": .string(scope.workingDirectory ?? scope.outputDirectory), "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"), "sandbox": .string("workspace-write"), "developerInstructions": .string(AssistantPrompts.agentRules)]
    }
    private func isolatedParameters(_ scope: TaskScope) async throws -> [String: ToolValue] {
        // Inspect a temporary, turn-free thread so generated app servers are
        // already excluded. No prompt or task data is sent to this probe.
        var probe = parameters(scope); probe["ephemeral"] = .bool(true)
        let result = try await transport.request("thread/start", .object(probe))
        guard let id = result["thread"]["id"].text else { throw ExecutionError.invalid("Codex 未返回配置检查会话。") }
        do {
            let servers = try await toolInventory(thread: id)
            var args = parameters(scope); args["config"] = try Self.isolatedConfiguration(scope, servers: servers)
            _ = try await transport.request("thread/unsubscribe", .object(["threadId": .string(id)]))
            return args
        } catch {
            _ = try? await transport.request("thread/unsubscribe", .object(["threadId": .string(id)]))
            throw error
        }
    }
    public func create(scope: TaskScope) async throws -> String {
        var parameters = try await isolatedParameters(scope); parameters["serviceName"] = .string("jotbloom")
        let result = try await transport.request("thread/start", .object(parameters))
        guard let id = result["thread"]["id"].text else { throw ExecutionError.invalid("Codex 协议不兼容：未返回会话编号。") }; try await verifyIsolatedTools(thread: id); return id
    }
    public func resume(thread: String, scope: TaskScope) async throws {
        var parameters = try await isolatedParameters(scope); parameters["threadId"] = .string(thread); parameters["excludeTurns"] = .bool(true)
        _ = try await transport.request("thread/resume", .object(parameters))
        try await verifyIsolatedTools(thread: thread)
    }
    public func start(thread: String, scope: TaskScope, prompt: String) async throws -> String {
        let parameters: [String: ToolValue] = ["threadId": .string(thread), "cwd": .string(scope.workingDirectory ?? scope.outputDirectory), "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"), "sandboxPolicy": Self.sandbox(scope), "input": .array([.object(["type": .string("text"), "text": .string(prompt)])])]
        let result = try await transport.request("turn/start", .object(parameters))
        guard let id = result["turn"]["id"].text else { throw ExecutionError.invalid("Codex 协议不兼容：未返回轮次编号。") }; return id
    }
    public func steer(thread: String, turn: String, prompt: String) async throws {
        let result = try await transport.request("turn/steer", .object(["threadId": .string(thread), "expectedTurnId": .string(turn), "input": .array([.object(["type": .string("text"), "text": .string(prompt)])])]))
        guard result["turnId"].text == turn else { throw ExecutionError.invalid("未能确认补充送达当前 Codex 轮次，要求已保留。") }
    }
    public func respond(id: ToolValue, result: ToolValue) async throws { try await transport.response(id, result: result) }
    func reject(id: ToolValue) async { try? await transport.reject(id) }
    public func interrupt(thread: String, turn: String) async { _ = try? await transport.request("turn/interrupt", .object(["threadId": .string(thread), "turnId": .string(turn)])) }
    public func close() async { connectedPath = nil; await transport.close() }
}
