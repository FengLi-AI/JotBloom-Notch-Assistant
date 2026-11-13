import XCTest
@testable import JotBloomCore

private actor SupervisionCapture {
    var contexts: [String] = []
    var response: String
    var gate: CheckedContinuation<Void, Never>?
    let gated: Bool
    init(_ response: String, gated: Bool = false) { self.response = response; self.gated = gated }
    func call(_ context: String) async -> String {
        contexts.append(context)
        if gated { await withCheckedContinuation { gate = $0 } }
        return response
    }
    func release() { gate?.resume(); gate = nil }
    func count() -> Int { contexts.count }
}

extension AssistantExecutionTests {
    private func eventually(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<300 { if try await condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("supervision condition timed out")
    }
    private func runningAgent(_ model: AgentSupervisor.Model?) async throws -> (AssistantTask, FixtureAgentConnector, AgentTaskService, Task<AgentRunOutcome, Error>) {
        let task = try await prepared(allowCodex: true), fixture = FixtureAgentConnector(), service = AgentTaskService(store: store, connector: fixture)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        await service.configureSupervisor(model, interval: 0.01, delay: 0.001)
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        let work = Task { try await service.run(id: task.id, instruction: "执行原要求") }
        try await eventually { try await service.session(task.id).turnID != nil }
        return (task, fixture, service, work)
    }
    func testSupervisionCorrectsOnlyWithConfirmedScopeAndEscalatesAfterTwoAttempts() async throws {
        let model = SupervisionCapture(#"{"action":"correct","summary":"交付方向偏离已确认要求","evidenceID":"report:0"}"#)
        let (task, fixture, service, work) = try await runningAgent { await model.call($0) }
        for index in 1...3 {
            await fixture.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string("偏离观察 \(index)")])])
            try await eventually { await model.count() >= index }
            if index <= 2 { try await eventually { await fixture.steering().count == index } }
        }
        guard case .waiting = try await work.value else { return XCTFail() }
        let steers = await fixture.steering(), calls = await fixture.snapshot()
        XCTAssertEqual(steers.count, 2); XCTAssertEqual(calls.1, 0); XCTAssertEqual(calls.2, 1)
        XCTAssertTrue(steers.allSatisfy { $0.contains(task.scope!.goal) && $0.contains(task.scope!.doneCriteria) && !$0.contains("偏离观察") })
        let storedQuestion = try await store.executionQuestion(id: task.id)
        let question = try XCTUnwrap(storedQuestion)
        XCTAssertEqual(question.kind, "supervision")
        let saved = try await store.assistantTask(id: task.id); XCTAssertEqual(saved?.scope, task.scope)
        try await store.answerExecutionQuestion(id: task.id, questionID: question.id, allow: true, selected: [], answer: "保留原来的完成标准")
        let resumed = try await store.assistantTask(id: task.id); XCTAssertEqual(resumed?.status, .queued); XCTAssertEqual(resumed?.scope, task.scope)
        await service.shutdown()
    }
    func testSeriousDeviationPausesForDecisionWithoutSteeringOrGrantingPermission() async throws {
        let model = SupervisionCapture(#"{"action":"askUser","summary":"需要改变交付范围","evidenceID":"report:0","question":"Codex 希望改做在线服务，是否继续原来的本地文件方案？"}"#)
        let (task, fixture, service, work) = try await runningAgent { await model.call($0) }
        await fixture.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string("需要改为在线服务并登录")])])
        guard case .waiting = try await work.value else { return XCTFail() }
        let storedQuestion = try await store.executionQuestion(id: task.id)
        let question = try XCTUnwrap(storedQuestion)
        let calls = await fixture.snapshot(), steers = await fixture.steering()
        XCTAssertEqual(question.kind, "supervision"); XCTAssertEqual(calls.1, 0); XCTAssertEqual(calls.2, 1); XCTAssertTrue(steers.isEmpty)
        try await store.answerExecutionQuestion(id: task.id, questionID: question.id, allow: false, selected: [], answer: "")
        let saved = try await store.assistantTask(id: task.id)
        XCTAssertEqual(saved?.status, .cancelled); XCTAssertEqual(saved?.scope, task.scope)
        await service.shutdown()
    }
    func testNormalProgressOnlyUpdatesSummaryWithoutInterrupting() async throws {
        let model = SupervisionCapture(#"{"action":"onTrack","summary":"已开始整理资料，接下来核对完成标准。"}"#)
        let (task, fixture, service, work) = try await runningAgent { await model.call($0) }
        await fixture.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string("正在整理资料")])])
        try await eventually { try await service.session(task.id).supervision?.reviewedRevision == 1 }
        let calls = await fixture.snapshot(), steers = await fixture.steering(), saved = try await store.assistantTask(id: task.id)
        XCTAssertEqual(calls.2, 0); XCTAssertTrue(steers.isEmpty); XCTAssertEqual(saved?.status, .running)
        await service.stop(id: task.id); _ = try? await work.value; await service.shutdown()
    }
    func testSupervisorCannotActOnPendingApprovalOrSeeRawCommandOutput() async throws {
        let model = SupervisionCapture(#"{"action":"correct","summary":"检查原要求","evidenceID":"report:0"}"#, gated: true)
        let (task, fixture, service, work) = try await runningAgent { await model.call($0) }
        await fixture.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string("准备核对结果")])])
        try await eventually { await model.count() == 1 }
        await fixture.emit("item/commandExecution/outputDelta", values: ["delta": .string("SECRET_COMMAND_OUTPUT")])
        await fixture.emit("item/commandExecution/requestApproval", request: .number(400), values: ["command": .string("PRIVATE_APPROVAL_COMMAND")])
        guard case .waiting = try await work.value else { return XCTFail() }
        await model.release()
        try await Task.sleep(nanoseconds: 30_000_000)
        let steers = await fixture.steering(), calls = await fixture.snapshot(), contexts = await model.contexts
        XCTAssertTrue(steers.isEmpty); XCTAssertEqual(calls.1, 0)
        XCTAssertFalse(contexts.joined().contains("PRIVATE_APPROVAL_COMMAND")); XCTAssertFalse(contexts.joined().contains("SECRET_COMMAND_OUTPUT"))
        let session = try await service.session(task.id); XCTAssertNotNil(session.pending)
        await service.shutdown()
    }
    func testUserSupplementSteersSameTurnWithoutInterruptOrPermissionChange() async throws {
        let (task, fixture, service, work) = try await runningAgent(nil)
        try await store.supplementExecution(id: task.id, text: "请保持蓝白配色")
        let delivered = try await service.steerFromUser(id: task.id, text: "请保持蓝白配色")
        XCTAssertTrue(delivered)
        let calls = await fixture.snapshot(), messages = await fixture.steering()
        XCTAssertEqual(calls.0, 1); XCTAssertEqual(calls.2, 0); XCTAssertEqual(messages.count, 1)
        let saved = try await store.assistantTask(id: task.id); XCTAssertEqual(saved?.scope, task.scope)
        await service.stop(id: task.id); _ = try? await work.value; await service.shutdown()
    }
    func testSupervisionBudgetStopsBeforeAnotherModelCall() async throws {
        let model = SupervisionCapture(#"{"action":"onTrack","summary":"正常推进"}"#)
        let (task, fixture, service, work) = try await runningAgent { await model.call($0) }
        var state = try await store.executionState(id: task.id); state.calls = state.stepLimit
        try await store.saveExecutionState(id: task.id, state: state)
        await fixture.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string("检查进展")])])
        guard case .waiting = try await work.value else { return XCTFail() }
        let count = await model.count(), question = try await store.executionQuestion(id: task.id)
        XCTAssertEqual(count, 0); XCTAssertEqual(question?.kind, "budget")
        await service.shutdown()
    }
    func testSupervisionRejectsInventedEvidenceAndPreservesLegacySessions() throws {
        var session = AgentSession(); session.supervision = .init(); session.supervision?.observe(report: "已有结果")
        XCTAssertEqual(try AgentSupervisor.parse("```json\n{\"action\":\"onTrack\",\"summary\":\"正在推进\"}\n```", session: session).action, .onTrack)
        XCTAssertThrowsError(try AgentSupervisor.parse(#"{"action":"correct","summary":"偏离","evidenceID":"invented"}"#, session: session))
        XCTAssertThrowsError(try AgentSupervisor.parse(#"{"action":"askUser","summary":"等用户","evidenceID":"report:0"}"#, session: session))
        let old = AgentSession(); let json = try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(AgentSession.self, from: json).supervision)
        XCTAssertNotNil(AgentThreadLink.url("01a1c56b-02c0-7d20-ab75-f7defe0b8cc8"))
        for invalid in ["../new", "new?prompt=send", "x#other", "", "x/y"] { XCTAssertNil(AgentThreadLink.url(invalid)) }
    }
    func testImagePreviewReadsOnlyBoundedRegularResults() throws {
        let files = try AssistantResultFiles(directory: root.appendingPathComponent("images").path)
        let data = Data([0x89, 0x50, 0x4e, 0x47])
        try data.write(to: URL(fileURLWithPath: files.directory + "/image.png"))
        XCTAssertEqual(try files.readImage("image.png"), data)
        try FileManager.default.createSymbolicLink(atPath: files.directory + "/escape.png", withDestinationPath: "/etc/hosts")
        for name in ["escape.png", "../image.png", ".hidden.png", "file.svg"] { XCTAssertThrowsError(try files.readImage(name)) }
        try Data(repeating: 0, count: 20 * 1_048_576 + 1).write(to: URL(fileURLWithPath: files.directory + "/big.png"))
        XCTAssertThrowsError(try files.readImage("big.png"))
    }
}
