import XCTest
@testable import JotBloomCore

@MainActor
final class AssistantPhaseOneClosureTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private func time(_ text: String) -> Int64 { AssistantDates.parse(text, timeZone: zone)! }
    private func plan() -> AssistantPlan {
        .init(brief: .init(title: "整理资料", summary: "交付单文件 HTML", deliverable: "网页", requester: "用户", deadline: nil, remindAt: nil, questions: [], assumptions: ["界面用蓝色"], keywords: [], doneCriteria: "离线打开可用", approach: ["先实现键盘操作"], needsWork: true, needsCodex: true, needsNetwork: false), dueAt: nil, reminders: [], materials: [], outputDirectory: "/unused")
    }
    func testRescheduleUsesCustomDefaultsAndPreservesAllNonAutomaticOrigins() throws {
        var value = plan()
        value.reschedule(due: time("2030-06-10T18:00"), now: time("2030-06-01T08:00"), timeZone: zone, dayBeforeMinute: 8 * 60 + 35, sameDayMinute: 7 * 60 + 20)
        XCTAssertEqual(value.reminders, [time("2030-06-09T08:35"), time("2030-06-10T07:20")])
        value.editReminder(at: 0, time: time("2030-06-11T11:00"))
        value.addReminder(time("2030-06-12T12:00"), origin: .explicit)
        value.addReminder(time("2030-06-13T13:00"), origin: .agent)
        let preserved = value.reminders.filter { value.reminderOrigin(at: $0) != .auto }
        value.reschedule(due: time("2030-06-08T18:00"), now: time("2030-06-01T08:00"), timeZone: zone, dayBeforeMinute: 16 * 60, sameDayMinute: 15 * 60)
        XCTAssertEqual(value.reminders.filter { value.reminderOrigin(at: $0) == .auto }, [time("2030-06-07T16:00"), time("2030-06-08T15:00")])
        XCTAssertEqual(Set(preserved), Set(value.reminders.filter { value.reminderOrigin(at: $0) != .auto }))
        XCTAssertTrue(preserved.allSatisfy(value.reminderIsAfterDeadline))
        XCTAssertEqual(value.reminderOrigin(at: preserved[0]), .user)
        value.reschedule(due: nil, now: time("2030-06-01T08:00"), timeZone: zone, dayBeforeMinute: 600, sameDayMinute: 540)
        XCTAssertEqual(Set(value.reminders), Set(preserved))
        XCTAssertFalse(value.reminders.contains(where: value.reminderIsAfterDeadline))
        let decoded = try JSONDecoder().decode(AssistantPlan.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }
    func testLegacyPlansDefaultToAutoAndDisabledRemindersStayDisabled() throws {
        var value = plan(); value.dueAt = time("2030-06-10T18:00"); value.reminders = [time("2030-06-09T10:00")]
        let decoded = try JSONDecoder().decode(AssistantPlan.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.reminderOrigin(at: decoded.reminders[0]), .auto)
        value.removeReminder(at: 0)
        value.reschedule(due: time("2030-06-12T18:00"), now: 1, timeZone: zone, dayBeforeMinute: 1, sameDayMinute: 2)
        XCTAssertTrue(value.reminders.isEmpty)
        value.addReminder(time("2030-06-15T12:00"), origin: .explicit)
        value.reschedule(due: time("2030-06-13T18:00"), now: 1, timeZone: zone, dayBeforeMinute: 1, sameDayMinute: 2)
        XCTAssertEqual(value.reminders, [time("2030-06-15T12:00")])
    }
    private func scope(_ value: AssistantPlan) -> TaskScope {
        .init(goal: value.brief.summary, doneCriteria: value.brief.doneCriteria, materials: [], autoFind: false, allowCodex: true, allowNetwork: false, confirmedAnswers: ["受众是初中生"], outputDirectory: value.outputDirectory)
    }
    private func answer(id: String = "reply", source: String = "goal", quote: String = "单文件 HTML") -> AssistantStepAction {
        .init(tool: .continueCodex, args: ["instructions": .string("不得发送这条未核验的附加要求"), "answersCodexQuestion": .bool(true), "answerEvidence": .array([.object(["questionID": .string(id), "sourceID": .string(source), "quote": .string(quote)])])])
    }
    func testKnownAnswersRequireExactGoalUserAnswerOrVisiblePlanEvidence() {
        let value = plan(), boundary = scope(value)
        for (source, quote) in [("goal", "单文件 HTML"), ("answer.0", "受众是初中生"), ("assumption.0", "界面用蓝色"), ("approach.0", "先实现键盘操作"), ("outputDirectory", "/unused"), ("title", "整理资料")] {
            let result = AgentKnownAnswer.answers(answer(source: source, quote: quote), questions: [.init(id: "reply", text: "这个要求是什么？", options: [])], scope: boundary, plan: value, state: .init())
            XCTAssertEqual(result, ["reply": quote])
        }
        for action in [answer(source: "material.0"), answer(quote: "凭空推测"), answer(id: "wrong"), .init(tool: .continueCodex, args: ["instructions": .string("随便回答"), "answersCodexQuestion": .bool(true)])] {
            XCTAssertNil(AgentKnownAnswer.answers(action, questions: [.init(id: "reply", text: "什么格式？", options: [])], scope: boundary, plan: value, state: .init()))
        }
    }
    func testSensitiveUnknownAndAskAlwaysQuestionsNeverReceiveAutomaticAnswers() {
        let value = plan(); var boundary = scope(value)
        for question in ["费用可以支付吗", "发布到哪里", "使用哪个账号", "Which account?", "May I deploy?", "Approve the payment?"] {
            XCTAssertNil(AgentKnownAnswer.answers(answer(), questions: [.init(id: "reply", text: question, options: [])], scope: boundary, plan: value, state: .init()))
        }
        boundary.permissionMode = "askAlways"
        XCTAssertNil(AgentKnownAnswer.answers(answer(), questions: [.init(id: "reply", text: "什么格式？", options: [])], scope: boundary, plan: value, state: .init()))
    }
    private func prepared(store: JotBloomStore, root: URL, strict: Bool = false) async throws -> AssistantTask {
        let task = try await store.createAssistantTask(id: UUID().uuidString, input: "交付单文件 HTML", source: .notchText, attachments: [])
        try await store.beginAssistantUnderstanding(id: task.id, answer: nil, adjustment: nil)
        var value = plan(); value.allowCodex = true; value.permissionMode = strict ? "askAlways" : "balanced"
        value.outputDirectory = root.appendingPathComponent("output").path
        try await store.saveAssistantUnderstanding(id: task.id, brief: value.brief, plan: value, directReminder: false)
        try await store.confirmAssistantPlan(id: task.id, plan: value, now: 1)
        return try await store.assistantTask(id: task.id)!
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<400 { if try await predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Timed out waiting for fixture"); throw AssistantError.unavailable
    }
    func testOrdinaryRPCAnswerIsGroundedRecordedAndSentOnlyAfterRequeue() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let task = try await prepared(store: store, root: root), connector = FixtureAgentConnector()
        let service = AgentTaskService(store: store, connector: connector)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        let fixture = ClosureAnswerModel(actions: [.init(tool: .delegateToCodex, args: ["instructions": .string("执行任务")]), answer(id: "format")])
        let run = Task { await TaskRuntime(store: store, model: { await fixture.next($0) }, agent: service).run(id: task.id) }
        try await wait { await connector.snapshot().0 == 1 }
        await connector.emit("item/tool/requestUserInput", request: .number(91), values: ["questions": .array([.object(["id": .string("format"), "question": .string("交付什么格式？")])])])
        await run.value
        let queued = try await store.assistantTask(id: task.id), before = await connector.snapshot()
        XCTAssertEqual(queued?.status, .queued); XCTAssertEqual(before.1, 0)
        let events = try await store.assistantEvents(taskID: task.id)
        XCTAssertTrue(events.contains { $0.text.contains("已依据确认内容回答 Codex：单文件 HTML") })
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        let resumed = Task { try await service.run(id: task.id, instruction: nil) }
        try await wait { await connector.snapshot().1 == 1 }
        let response = await connector.replies.last?.1
        XCTAssertEqual(response?["answers"]["format"]["answers"].strings, ["单文件 HTML"])
        await connector.emit("turn/completed", values: ["turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        _ = try await resumed.value; await service.shutdown()
    }
    func testNaturalLanguageQuestionFallsBackToUserForMissingEvidenceSensitiveAndStrict() async throws {
        for (strict, question, proposal) in [(false, "需要什么格式？", answer(quote: "无证据的答案")), (false, "是否付费发布？", answer()), (true, "需要什么格式？", answer()), (false, "请确认交付格式", .init(tool: .continueCodex, args: ["instructions": .string("模型遗漏答题标记并凭空作答")]))] {
            let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
            let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
            let task = try await prepared(store: store, root: root, strict: strict), connector = FixtureAgentConnector()
            let service = AgentTaskService(store: store, connector: connector)
            await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
            let fixture = ClosureAnswerModel(actions: [.init(tool: .delegateToCodex, args: ["instructions": .string("执行")]), proposal])
            let run = Task { await TaskRuntime(store: store, model: { await fixture.next($0) }, agent: service).run(id: task.id) }
            try await wait { await connector.snapshot().0 == 1 }
            await connector.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string(question)])])
            await connector.emit("turn/completed", values: ["turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
            await run.value
            let pending = try await store.executionQuestion(id: task.id), saved = try await store.assistantTask(id: task.id)
            XCTAssertEqual(saved?.status, .waitingUser); XCTAssertEqual(pending?.text, question)
            let calls = await connector.snapshot(); XCTAssertEqual(calls.0, 1)
            await service.shutdown()
        }
    }
    func testNaturalLanguageKnownAnswerContinuesSameThreadAndRecordsCheckedQuote() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let task = try await prepared(store: store, root: root), connector = FixtureAgentConnector()
        let service = AgentTaskService(store: store, connector: connector)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        let fixture = ClosureAnswerModel(actions: [.init(tool: .delegateToCodex, args: ["instructions": .string("执行")]), answer(), .init(tool: .askUser, args: ["question": .string("请检查测试结果")])])
        let run = Task { await TaskRuntime(store: store, model: { await fixture.next($0) }, agent: service).run(id: task.id) }
        try await wait { await connector.snapshot().0 == 1 }
        await connector.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string("交付什么格式？")])])
        await connector.emit("turn/completed", values: ["turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        try await wait { await connector.snapshot().0 == 2 }
        let prompts = await connector.prompts(), sessions = await connector.starts.map { $0.0 }
        XCTAssertEqual(Set(sessions), ["thread-1"])
        XCTAssertTrue(prompts.last?.contains("本次要求：单文件 HTML") == true)
        XCTAssertFalse(prompts.last?.contains("不得发送这条未核验的附加要求") == true)
        await connector.emit("turn/completed", turn: "turn-2", values: ["turn": .object(["id": .string("turn-2"), "status": .string("completed")])])
        await run.value
        let events = try await store.assistantEvents(taskID: task.id)
        XCTAssertTrue(events.contains { $0.kind == "agentAnswer" && $0.text.contains("单文件 HTML") })
        await service.shutdown()
    }
    func testRPCStrictSensitiveUnknownAndApprovalRequestsRemainHumanOwned() async throws {
        for (strict, text, method, quote) in [(true, "交付什么格式？", "item/tool/requestUserInput", "单文件 HTML"), (false, "发布到哪个账号？", "item/tool/requestUserInput", "单文件 HTML"), (false, "预算够吗？", "item/tool/requestUserInput", "单文件 HTML"), (false, "交付什么格式？", "item/tool/requestUserInput", "未确认的猜测"), (false, "", "item/commandExecution/requestApproval", "单文件 HTML")] {
            let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
            let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
            let task = try await prepared(store: store, root: root, strict: strict), connector = FixtureAgentConnector()
            let service = AgentTaskService(store: store, connector: connector)
            await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
            let fixture = ClosureAnswerModel(actions: [.init(tool: .delegateToCodex, args: ["instructions": .string("执行")]), answer(id: "q", quote: quote)])
            let run = Task { await TaskRuntime(store: store, model: { await fixture.next($0) }, agent: service).run(id: task.id) }
            try await wait { await connector.snapshot().0 == 1 }
            await connector.emit(method, request: .number(3), values: ["command": .string("APPROVAL_MUST_NOT_REACH_MODEL"), "questions": .array([.object(["id": .string("q"), "question": .string(text)])])])
            await run.value
            let saved = try await store.assistantTask(id: task.id), pending = try await store.executionQuestion(id: task.id)
            XCTAssertEqual(saved?.status, .waitingUser); XCTAssertNotNil(pending)
            let result = try await service.answerKnownInput(id: task.id, questionID: pending!.id, action: answer(id: "q", quote: quote))
            XCTAssertFalse(result)
            let responses = await connector.snapshot(); XCTAssertEqual(responses.1, 0)
            let contexts = await fixture.contexts
            XCTAssertFalse(contexts.joined().contains("APPROVAL_MUST_NOT_REACH_MODEL"))
            XCTAssertEqual(contexts.count, !strict && quote == "未确认的猜测" ? 2 : 1)
            await service.shutdown()
        }
    }
    func testRuntimeReminderUndoRestoresEachPreviousOrigin() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let task = try await prepared(store: store, root: root)
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        for (index, origin) in [AssistantReminderOrigin.auto, .user, .explicit, .agent].enumerated() {
            let oldTime = time("2099-06-10T12:00") + Int64(index * 60000)
            try store.performSync { db in try JotBloomStore.insertAssistantReminders(db, id: task.id, times: [oldTime], origins: [String(oldTime): origin]) }
            let rows = try await store.assistantReminders(), row = try XCTUnwrap(rows.first { $0.fireAt == oldTime })
            let action = AssistantStepAction(tool: .setReminder, args: ["time": .string("2099-06-11T12:00"), "id": .string(row.id)])
            let step = try await store.beginExecutionStep(id: task.id, action: action, decision: "allowAndRecord")
            _ = try await store.executeRecordedEffect(id: task.id, stepID: step, action: action)
            let changed = try await store.assistantReminders(); XCTAssertEqual(changed.first { $0.id == row.id }?.origin, .agent)
            try await store.undoExecutionEffect(id: task.id, stepID: step)
            let restored = try await store.assistantReminders(); XCTAssertEqual(restored.first { $0.id == row.id }?.origin, origin)
            XCTAssertEqual(restored.first { $0.id == row.id }?.fireAt, oldTime)
        }
    }
    func testResultJudgmentTransportFailurePreservesRawReplyForHumanDecision() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let task = try await prepared(store: store, root: root), connector = FixtureAgentConnector()
        let service = AgentTaskService(store: store, connector: connector)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        let fixture = FailingResultModel()
        let run = Task { await TaskRuntime(store: store, model: { try await fixture.next($0) }, agent: service).run(id: task.id) }
        try await wait { await connector.snapshot().0 == 1 }
        let raw = "文件已生成，但仍需检查交互。"
        await connector.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string(raw)])])
        await connector.emit("turn/completed", values: ["turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        await run.value
        let saved = try await store.assistantTask(id: task.id), question = try await store.executionQuestion(id: task.id)
        XCTAssertEqual(saved?.status, .waitingUser); XCTAssertEqual(question?.kind, "codexResult")
        XCTAssertTrue(question?.text.contains(raw) == true)
        let count = await fixture.calls; XCTAssertEqual(count, 3)
        await service.shutdown()
    }
    func testStrictModeForwardsActualUserAnswerWithoutAskingAgainOrModelRewriting() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let store = try JotBloomStore(dataDirectoryURL: root); defer { store.close() }
        let task = try await prepared(store: store, root: root, strict: true), connector = FixtureAgentConnector()
        let service = AgentTaskService(store: store, connector: connector)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        let first = ClosureAnswerModel(actions: [.init(tool: .delegateToCodex, args: ["instructions": .string("执行")]), answer()])
        let initial = Task { await TaskRuntime(store: store, model: { await first.next($0) }, agent: service).run(id: task.id) }
        try await wait { await connector.snapshot().0 == 1 }
        await connector.emit("item/completed", values: ["item": .object(["type": .string("agentMessage"), "text": .string("交付什么格式？")])])
        await connector.emit("turn/completed", values: ["turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        await initial.value
        let pending = try await store.executionQuestion(id: task.id)
        XCTAssertEqual(pending?.codexThreadID, "thread-1")
        try await store.answerExecutionQuestion(id: task.id, questionID: pending!.id, allow: true, selected: [], answer: "做成一个 HTML，保留代号 BX-42。")
        let second = ClosureAnswerModel(actions: [.init(tool: .askUser, args: ["question": .string("测试结束，请核对")])])
        let resumed = Task { await TaskRuntime(store: store, model: { await second.next($0) }, agent: service).run(id: task.id) }
        try await wait { await connector.snapshot().0 == 2 }
        let callsBeforeCodexReply = await second.contexts.count, prompts = await connector.prompts()
        XCTAssertEqual(callsBeforeCodexReply, 0)
        XCTAssertTrue(prompts.last?.contains("做成一个 HTML，保留代号 BX-42。") == true)
        let state = try await store.executionState(id: task.id); XCTAssertNil(state.codexUserAnswer)
        await connector.emit("turn/completed", turn: "turn-2", values: ["turn": .object(["id": .string("turn-2"), "status": .string("completed")])])
        await resumed.value; await service.shutdown()
    }
}

private actor ClosureAnswerModel {
    var actions: [AssistantStepAction]
    var contexts: [String] = []
    init(actions: [AssistantStepAction]) { self.actions = actions }
    func next(_ context: String) -> String {
        contexts.append(context)
        guard !actions.isEmpty else { return "invalid" }
        return String(decoding: try! JSONEncoder().encode(actions.removeFirst()), as: UTF8.self)
    }
}

private actor FailingResultModel {
    var calls = 0
    func next(_ context: String) throws -> String {
        calls += 1
        if calls > 1 { throw URLError(.timedOut) }
        return String(decoding: try JSONEncoder().encode(AssistantStepAction(tool: .delegateToCodex, args: ["instructions": .string("执行")])), as: UTF8.self)
    }
}
