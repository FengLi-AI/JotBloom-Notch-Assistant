import Foundation

enum AgentRPCError: Error, LocalizedError {
    case methodNotFound
    var errorDescription: String? { "Codex 版本不支持所需接口。" }
}

/// One stdio connection. No shell, credentials, request bodies or stderr are logged.
actor AgentRPCTransport {
    nonisolated let events: AsyncStream<AgentEvent>
    private let output: AsyncStream<AgentEvent>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var sequence = 0
    private var generation = UUID()
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<ToolValue, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    static let maximumLine = 16 * 1024 * 1024
    init() {
        var continuation: AsyncStream<AgentEvent>.Continuation!
        events = AsyncStream { continuation = $0 }; output = continuation
    }
    func isRunning() -> Bool { process?.isRunning == true }
    func launch(_ path: String, arguments: [String] = ["app-server"]) throws {
        guard process == nil else { return }
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: path); child.arguments = arguments
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        let token = UUID(); generation = token; buffer.removeAll()
        child.terminationHandler = { [weak self] _ in Task { await self?.exited(token) } }
        try child.run(); process = child; input = stdin.fileHandleForWriting
        Task.detached(priority: .utility) { [weak self] in
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { break }
                await self?.consume(data, generation: token)
            }
        }
        Task.detached(priority: .utility) {
            // Drain continuously without retaining potentially sensitive diagnostics.
            while !stderr.fileHandleForReading.availableData.isEmpty {}
        }
    }
    func request(_ method: String, _ params: ToolValue, timeout: UInt64 = 30_000_000_000) async throws -> ToolValue {
        sequence += 1; let id = sequence
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do { try send(.object(["id": .number(Double(id)), "method": .string(method), "params": params])) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    await self?.expire(id)
                }
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    func notify(_ method: String) throws { try send(.object(["method": .string(method)])) }
    func response(_ id: ToolValue, result: ToolValue) throws { try send(.object(["id": id, "result": result])) }
    func reject(_ id: ToolValue) throws {
        try send(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported request; no permission granted")])]))
    }
    private func send(_ message: ToolValue) throws {
        guard let input, process?.isRunning == true else { throw ExecutionError.unreadable("Codex 连接已断开，请继续任务重新连接。") }
        var data = try JSONEncoder().encode(message); data.append(10)
        try input.write(contentsOf: data)
    }
    private func consume(_ data: Data, generation token: UUID) async {
        guard token == generation else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= Self.maximumLine else { await close(); return }
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(ToolValue.self, from: line) else { await close(); return }
            if message["method"].text != nil { output.yield(.message(message)); continue }
            if case .number(let number) = message["id"], let callback = pending.removeValue(forKey: Int(number)) {
                deadlines.removeValue(forKey: Int(number))?.cancel()
                if message.object["error"] != nil {
                    // Don't surface arbitrary server payloads or paths in general alerts.
                    if message["error"]["code"] == .number(-32601) { callback.resume(throwing: AgentRPCError.methodNotFound) }
                    else { callback.resume(throwing: ExecutionError.unreadable("Codex 未接受这次请求，请检查登录、版本或任务会话；已有文件保留。")) }
                } else { callback.resume(returning: message["result"]) }
            }
        }
        if buffer.count > Self.maximumLine { await close() }
    }
    private func expire(_ id: Int) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: ExecutionError.unreadable("Codex 响应超时，未确认的操作不会自动重发。"))
    }
    private func cancel(_ id: Int) { deadlines.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    private func exited(_ token: UUID) {
        guard token == generation else { return }
        process = nil; try? input?.close(); input = nil; buffer.removeAll()
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        let callbacks = pending.values; pending.removeAll()
        callbacks.forEach { $0.resume(throwing: ExecutionError.unreadable("Codex 进程已退出，任务已保留，可继续。")) }
        output.yield(.closed)
    }
    func close() async {
        guard let child = process else { return }
        let token = generation
        try? input?.close(); input = nil
        if child.isRunning { child.terminate() }
        for _ in 0..<20 {
            if !child.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        exited(token)
    }
}
