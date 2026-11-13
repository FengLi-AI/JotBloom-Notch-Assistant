import XCTest
@testable import JotBloomCore

actor FixtureAgentConnector: AgentConnector {
    nonisolated let events: AsyncStream<AgentEvent>
    let stream: AsyncStream<AgentEvent>.Continuation
    var starts: [(String, TaskScope, String)] = []
    var replies: [(ToolValue, ToolValue)] = []
    var resumes: [String] = []
    var interrupts = 0
    var steers: [String] = []
    var next = 0
    var autoFinish = false
    init() {
        var continuation: AsyncStream<AgentEvent>.Continuation!
        events = AsyncStream { continuation = $0 }; stream = continuation
    }
    func connect(path: String) async throws -> AgentAvailability { .init(ready: true, message: "fixture", path: path) }
    func create(scope: TaskScope) async throws -> String { next += 1; return "thread-\(next)" }
    func resume(thread: String, scope: TaskScope) async throws { resumes.append(thread) }
    func start(thread: String, scope: TaskScope, prompt: String) async throws -> String {
        starts.append((thread, scope, prompt)); let turn = "turn-\(starts.count)"
        if autoFinish {
            try "# REAL_FILE".write(toFile: scope.outputDirectory + "/result.md", atomically: true, encoding: .utf8)
            Task { try? await Task.sleep(nanoseconds: 30_000_000); emit("item/completed", thread: thread, turn: turn, values: ["item": .object(["type": .string("agentMessage"), "text": .string("已保存 result.md")])]); emit("turn/completed", thread: thread, turn: turn, values: ["turn": .object(["id": .string(turn), "status": .string("completed")])]) }
        }
        return turn
    }
    func respond(id: ToolValue, result: ToolValue) async throws { replies.append((id, result)) }
    func steer(thread: String, turn: String, prompt: String) async throws { steers.append(prompt) }
    func steering() -> [String] { steers }
    func interrupt(thread: String, turn: String) async { interrupts += 1 }
    func close() async { stream.yield(.closed) }
    func setAutoFinish() { autoFinish = true }
    func emit(_ method: String, thread: String = "thread-1", turn: String = "turn-1", request: ToolValue? = nil, values: [String: ToolValue] = [:]) {
        var params = values; params["threadId"] = .string(thread); params["turnId"] = .string(turn)
        var message: [String: ToolValue] = ["method": .string(method), "params": .object(params)]
        message["id"] = request; stream.yield(.message(.object(message)))
    }
    func snapshot() -> (Int, Int, Int) { (starts.count, replies.count, interrupts) }
    func prompts() -> [String] { starts.map { $0.2 } }
}

extension AssistantExecutionTests {
    func testAgentSandboxExcludesBothTemporaryWriteRootsAndUsesExactScope() async throws {
        var scope = try await prepared(allowCodex: true).scope!
        scope.workingDirectory = "/Users/example/project"
        let policy = CodexConnector.sandbox(scope)
        XCTAssertEqual(policy["writableRoots"].strings, [scope.outputDirectory, "/Users/example/project"])
        XCTAssertEqual(policy["type"].text, "workspaceWrite")
        XCTAssertTrue(policy["excludeSlashTmp"].bool); XCTAssertTrue(policy["excludeTmpdirEnvVar"].bool)
        XCTAssertFalse(policy["networkAccess"].bool)
    }
    func testAgentPermissionGateRejectsUnapprovedDelegationAndStrictAutomaticAnswers() async throws {
        var scope = try await prepared().scope!
        let action = AssistantStepAction(tool: .delegateToCodex, args: ["instructions": .string("create")])
        guard case .deny = PermissionGate.decide(action, scope: scope, state: .init()) else { return XCTFail() }
        scope.allowCodex = true
        XCTAssertEqual(PermissionGate.decide(action, scope: scope, state: .init()), .allow)
        scope.permissionMode = "askAlways"
        guard case .deny = PermissionGate.decide(.init(tool: .continueCodex, args: ["instructions": .string("answer"), "answersCodexQuestion": .bool(true)]), scope: scope, state: .init()) else { return XCTFail() }
    }
    func testAgentApprovalNeverAcceptsModelTextOrAddsPersistentRules() throws {
        let params: ToolValue = .object(["command": .string("echo harmless"), "proposedExecpolicyAmendment": .array([.string("sh")])])
        let question = try XCTUnwrap(AgentApprovalPolicy.question(method: "item/commandExecution/requestApproval", params: params, id: .string("server-7")))
        XCTAssertEqual(try AgentApprovalPolicy.response(question, decision: .once, answers: ["model": "allow"]), .object(["decision": .string("accept")]))
        XCTAssertEqual(try AgentApprovalPolicy.response(question, decision: .session, answers: [:]), .object(["decision": .string("acceptForSession")]))
        XCTAssertEqual(try AgentApprovalPolicy.response(question, decision: .decline, answers: [:]), .object(["decision": .string("decline")]))
        XCTAssertThrowsError(try AgentApprovalPolicy.response(question, decision: .answer, answers: ["model": "allow"]))
    }
    func testAgentNetworkGrantIsOnlyPreauthorizedNetworkAndCurrentTurn() async throws {
        var scope = try await prepared(allowCodex: true).scope!; scope.allowNetwork = true
        let method = "item/permissions/requestApproval"
        var params: ToolValue = .object(["permissions": .object(["network": .object(["enabled": .bool(true)])])])
        XCTAssertEqual(AgentApprovalPolicy.automaticNetwork(method: method, params: params, scope: scope)?["scope"].text, "turn")
        scope.permissionMode = "askAlways"; XCTAssertNil(AgentApprovalPolicy.automaticNetwork(method: method, params: params, scope: scope))
        scope.permissionMode = "balanced"; scope.allowNetwork = false
        XCTAssertNil(AgentApprovalPolicy.automaticNetwork(method: method, params: params, scope: scope))
        scope.allowNetwork = true
        params = .object(["permissions": .object(["network": .object(["enabled": .bool(true)]), "fileSystem": .object(["write": .array([.string("/outside")])])])])
        XCTAssertNil(AgentApprovalPolicy.automaticNetwork(method: method, params: params, scope: scope))
        XCTAssertNil(AgentApprovalPolicy.automaticNetwork(method: "item/commandExecution/requestApproval", params: params, scope: scope))
    }
    func testAgentQuestionOptionsRequireUserAnswerAndSecretFormsAreUnsupported() throws {
        let params: ToolValue = .object(["questions": .array([.object(["id": .string("color"), "question": .string("选哪一个？"), "options": .array([.object(["label": .string("蓝")])])])])])
        let question = try XCTUnwrap(AgentApprovalPolicy.question(method: "item/tool/requestUserInput", params: params, id: .number(9)))
        XCTAssertEqual(question.agent?.questions.first?.options, ["蓝"])
        XCTAssertThrowsError(try AgentApprovalPolicy.response(question, decision: .answer, answers: [:]))
        XCTAssertEqual(try AgentApprovalPolicy.response(question, decision: .answer, answers: ["color": "蓝"])["answers"]["color"]["answers"].strings, ["蓝"])
        let secret: ToolValue = .object(["questions": .array([.object(["id": .string("key"), "question": .string("Key?"), "isSecret": .bool(true)])])])
        XCTAssertNil(AgentApprovalPolicy.question(method: "item/tool/requestUserInput", params: secret, id: .number(1)))
        XCTAssertNil(AgentApprovalPolicy.question(method: "mcpServer/elicitation/request", params: .object(["mode": .string("url")]), id: .number(1)))
    }
    func testAgentOwnedThreadsSurviveTaskDeletionAndCannotReadUnselectedChat() async throws {
        let task = try await prepared(allowCodex: true)
        var session = AgentSession(); session.threadID = "owned-only"
        try await store.saveAgentSession(id: task.id, session: session)
        try await store.transitionAssistantTask(id: task.id, event: .failed, text: "fixture")
        try await store.deleteAssistantTask(id: task.id)
        let owned = try await store.ownedAgentThreads(); XCTAssertTrue(owned.contains("owned-only"))
        let prompt = AssistantPrompts.assignment(task: task, state: .init(), instruction: "检查", materials: [])
        XCTAssertFalse(prompt.contains("RAW_CHAT_NOT_FOR_EXECUTION")); XCTAssertTrue(prompt.contains(task.scope!.doneCriteria))
        let attachment = AssistantAttachment.file(root.appendingPathComponent("diagram.png"))
        let withFile = AssistantPrompts.assignment(task: task, state: .init(), instruction: "检查", materials: [(attachment, "图像参考")])
        XCTAssertTrue(withFile.contains(attachment.reference)); XCTAssertTrue(withFile.contains("只读"))
    }
    func testAgentWaitingReplyOnlySentAfterTaskHasReenteredExecutionSlot() async throws {
        let task = try await prepared(allowCodex: true), fixture = FixtureAgentConnector()
        let service = AgentTaskService(store: store, connector: fixture)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        let work = Task { try await service.run(id: task.id, instruction: "create") }
        try await waitForAgent { await fixture.snapshot().0 == 1 }
        await fixture.emit("item/commandExecution/requestApproval", request: .number(77), values: ["command": .string("RAW_APPROVAL_NOT_FOR_MODEL")])
        guard case .waiting = try await work.value else { return XCTFail() }
        let pendingValue = try await store.executionQuestion(id: task.id)
        let pending = try XCTUnwrap(pendingValue)
        try await service.answer(id: task.id, questionID: pending.id, decision: .once, answers: [:])
        let before = await fixture.snapshot(); XCTAssertEqual(before.1, 0)
        let status = try await store.assistantTask(id: task.id)?.status; XCTAssertEqual(status, .queued)
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        let resumed = Task { try await service.run(id: task.id, instruction: nil) }
        try await waitForAgent { await fixture.snapshot().1 == 1 }
        await fixture.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string("done")])])
        await fixture.emit("turn/completed", values: ["turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        guard case .finished(let text) = try await resumed.value else { return XCTFail() }; XCTAssertEqual(text, "done")
        do { try await service.answer(id: task.id, questionID: pending.id, decision: .once, answers: [:]); XCTFail("stale approval accepted") } catch {}
        let context = try TaskRuntime.context(scope: task.scope!, state: .init(), steps: try await store.executionSteps(id: task.id), reminders: [])
        XCTAssertFalse(context.contains("RAW_APPROVAL_NOT_FOR_MODEL"))
        await service.shutdown()
    }
    func testAgentUnclassifiableResultWaitsInsteadOfFalseSuccessOrFailure() async throws {
        let task = try await prepared(allowCodex: true), fixture = FixtureAgentConnector()
        await fixture.setAutoFinish()
        let service = AgentTaskService(store: store, connector: fixture)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        let model = AgentFixtureModel(first: json(.delegateToCodex, ["instructions": .string("write result")]), later: "malformed result")
        await TaskRuntime(store: store, model: { await model.next($0) }, agent: service).run(id: task.id)
        let saved = try await store.assistantTask(id: task.id), question = try await store.executionQuestion(id: task.id)
        XCTAssertEqual(saved?.status, .waitingUser); XCTAssertEqual(question?.kind, "codexResult")
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.scope!.outputDirectory + "/result.md"))
        await service.shutdown()
    }
    func testAgentCompletedTurnRequiresModelToCheckActualFile() async throws {
        let task = try await prepared(allowCodex: true), fixture = FixtureAgentConnector()
        await fixture.setAutoFinish()
        let service = AgentTaskService(store: store, connector: fixture)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        let model = AgentFixtureModel(first: json(.delegateToCodex, ["instructions": .string("write result")]), later: finish())
        await TaskRuntime(store: store, model: { await model.next($0) }, agent: service).run(id: task.id)
        let saved = try await store.assistantTask(id: task.id); XCTAssertEqual(saved?.status, .completed)
        let count = await model.count; XCTAssertEqual(count, 2)
        await service.shutdown()
    }
    func testAgentRecoveryInvalidatesApprovalAndPreservesIndependentThread() async throws {
        let task = try await prepared(allowCodex: true)
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        let q = try XCTUnwrap(AgentApprovalPolicy.question(method: "item/fileChange/requestApproval", params: .object([:]), id: .string("old-connection")))
        var session = AgentSession(); session.threadID = "persistent-thread"; session.active = true; session.pending = q
        try await store.saveAgentSession(id: task.id, session: session); try await store.waitForExecutionAnswer(id: task.id, question: q)
        try await store.recoverAgentSessions(); try await store.recoverAssistantTasks()
        let recovered = try await store.agentSession(id: task.id)
        XCTAssertEqual(recovered.threadID, "persistent-thread"); XCTAssertNil(recovered.pending); XCTAssertTrue(recovered.needsResume)
        let status = try await store.assistantTask(id: task.id)?.status; XCTAssertEqual(status, .interrupted)
        let question = try await store.executionQuestion(id: task.id); XCTAssertNil(question)
    }
    func testAgentAllResultTypesListButTextWriteRulesStayRestricted() throws {
        let files = try AssistantResultFiles(directory: root.appendingPathComponent("results").path)
        try "<h1>hello</h1>".write(toFile: files.directory + "/index.html", atomically: true, encoding: .utf8)
        try "hidden".write(toFile: files.directory + "/.hidden", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: files.directory + "/escape.html", withDestinationPath: "/etc/hosts")
        XCTAssertEqual(try files.list(allTypes: true).map(\.name), ["index.html"])
        XCTAssertTrue(try files.list().isEmpty)
        XCTAssertEqual(try files.read("index.html", allTypes: true), "<h1>hello</h1>")
        for name in ["../index.html", "/etc/hosts", ".hidden", "escape.html"] { XCTAssertThrowsError(try files.read(name, allTypes: true)) }
        try Data([0xFF, 0, 0xD8]).write(to: URL(fileURLWithPath: files.directory + "/binary.png"))
        XCTAssertThrowsError(try files.read("binary.png", allTypes: true))
        XCTAssertThrowsError(try files.write("index.html", content: "overwrite", mode: "overwrite"))
    }
    func testAgentGeneratedHTMLCanBeVerifiedByRuntimeWithoutBroadeningWrites() async throws {
        let task = try await prepared(allowCodex: true)
        try FileManager.default.createDirectory(atPath: task.scope!.outputDirectory, withIntermediateDirectories: true)
        try "<h1>M5_HTML_DELIVERY</h1>".write(toFile: task.scope!.outputDirectory + "/index.html", atomically: true, encoding: .utf8)
        let sequence = AgentFixtureModel(first: json(.readResult, ["name": .string("index.html")]), later: finish(true))
        let runtime = TaskRuntime(store: store, model: { await sequence.next($0) })
        await runtime.run(id: task.id)
        let steps = try await store.executionSteps(id: task.id)
        XCTAssertEqual(steps.first?.state, "done")
        XCTAssertTrue(steps.first?.result.contains("M5_HTML_DELIVERY") == true)
        XCTAssertThrowsError(try StepValidator.parse(write("index.html", "overwrite", mode: "overwrite")))
    }
    func testAgentWorkingFolderRejectsHomeSystemAndSymlinkAlias() throws {
        for path in ["/", "/System", "/private/tmp", FileManager.default.homeDirectoryForCurrentUser.path] { XCTAssertThrowsError(try AssistantFolders.validateWorking(path), path) }
        let alias = root.appendingPathComponent("home-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertThrowsError(try AssistantFolders.validateWorking(alias.path))
    }
    private func waitForAgent(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<200 { if try await predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw ExecutionError.invalid("fixture timeout")
    }
}
private actor AgentFixtureModel {
    var count = 0
    let first: String, later: String
    init(first: String, later: String) { self.first = first; self.later = later }
    func next(_ context: String) -> String { count += 1; return count == 1 ? first : later }
}

extension AssistantExecutionTests {
    func testAgentExplicitFailureBecomesFailedRatherThanAskingModelToDeclareSuccess() async throws {
        let task = try await prepared(allowCodex: true), fixture = FixtureAgentConnector()
        let service = AgentTaskService(store: store, connector: fixture)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        let work = Task { try await service.run(id: task.id, instruction: "fixture") }
        for _ in 0..<200 { if await fixture.snapshot().0 == 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        await fixture.emit("turn/completed", values: ["turn": .object(["id": .string("turn-1"), "status": .string("failed"), "error": .object(["codexErrorInfo": .string("usageLimitExceeded")])])])
        do { _ = try await work.value; XCTFail() } catch {}
        let saved = try await store.assistantTask(id: task.id)
        XCTAssertEqual(saved?.status, .failed); XCTAssertTrue(saved?.resultSummary?.contains("额度") == true)
        await service.shutdown()
    }
    func testAgentExternalInterruptPreservesResumeWithoutFalseCompletion() async throws {
        let task = try await prepared(allowCodex: true), fixture = FixtureAgentConnector()
        let service = AgentTaskService(store: store, connector: fixture)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        let work = Task { try await service.run(id: task.id, instruction: "fixture") }
        for _ in 0..<200 { if await fixture.snapshot().0 == 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        await fixture.emit("turn/completed", values: ["turn": .object(["id": .string("turn-1"), "status": .string("interrupted")])])
        do { _ = try await work.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await store.assistantTask(id: task.id), session = try await service.session(task.id)
        XCTAssertEqual(saved?.status, .interrupted); XCTAssertTrue(session.needsResume); XCTAssertFalse(session.awaitingInterpretation)
        await service.shutdown()
    }
    func testAgentApprovalDoesNotPersistServerEnvironmentOrRuleAmendment() throws {
        let params: ToolValue = .object(["env": .object(["SECRET": .string("SHOULD_NOT_PERSIST")]), "permissions": .object(["network": .object(["enabled": .bool(true)])]), "proposedExecpolicyAmendment": .array([.string("sh")])])
        let q = try XCTUnwrap(AgentApprovalPolicy.question(method: "item/permissions/requestApproval", params: params, id: .number(1)))
        let encoded = String(decoding: try JSONEncoder().encode(q), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SHOULD_NOT_PERSIST")); XCTAssertFalse(encoded.contains("proposedExecpolicyAmendment"))
    }
    func testAgentConfirmedAnswersEnterTaskPromptWithoutRawChat() async throws {
        var task = try await prepared(allowCodex: true)
        task.scope?.confirmedAnswers = ["受众：产品经理；代号 M5_EXACT_ANSWER"]
        let prompt = AssistantPrompts.assignment(task: task, state: .init(), instruction: "完成", materials: [])
        XCTAssertTrue(prompt.contains("M5_EXACT_ANSWER")); XCTAssertFalse(prompt.contains("RAW_CHAT_NOT_FOR_EXECUTION"))
        let context = try TaskRuntime.context(scope: task.scope!, state: .init(), steps: [], reminders: [])
        XCTAssertTrue(context.contains("M5_EXACT_ANSWER")); XCTAssertFalse(context.contains("RAW_CHAT_NOT_FOR_EXECUTION"))
    }
    func testCustomDefaultOutputLocationAndStrictModeOnlyAffectNewPlans() {
        let suite = "m5-settings-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AssistantAgentSettings(defaults: defaults)
        settings.mode = .askAlways; settings.outputParent = root.path
        let loaded = AssistantAgentSettings(defaults: defaults)
        XCTAssertEqual(loaded.mode, .askAlways); XCTAssertEqual(loaded.outputParent, root.path)
        let path = AssistantOutputLocation.suggested(title: "custom", now: Date(), reserved: [], parentPath: loaded.outputParent)
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().path, root.path)
    }
}

extension AssistantExecutionTests {
    func testAgentOfflineDisablesSearchAndInheritedPluginChannelsWithoutWritingConfig() async throws {
        var scope = try await prepared(allowCodex: true).scope!
        let servers: [ToolValue] = [.object(["name": .string("remote_tool")]), .object(["name": .string("plugin_tool"), "pluginId": .string("sample@vendor")])]
        let offline = try CodexConnector.isolatedConfiguration(scope, servers: servers)
        XCTAssertEqual(offline["web_search"].text, "disabled")
        XCTAssertEqual(offline["features.apps"], .bool(false))
        XCTAssertEqual(offline["mcp_servers.remote_tool.enabled"], .bool(false))
        XCTAssertEqual(offline["plugins.sample@vendor.enabled"], .bool(false))
        XCTAssertEqual(offline["mcp_servers.plugin_tool.enabled"], .null)
        XCTAssertThrowsError(try CodexConnector.isolatedConfiguration(scope, servers: [.object(["name": .string("other.enabled")])]))
        scope.allowNetwork = true
        let online = CodexConnector.sessionConfiguration(scope)
        XCTAssertEqual(online["web_search"].text, "live")
        XCTAssertEqual(online["features.apps"], .bool(false))
    }
}
