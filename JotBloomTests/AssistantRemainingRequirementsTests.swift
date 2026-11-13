import XCTest
@testable import JotBloomCore

@MainActor
final class AssistantRemainingRequirementsTests: XCTestCase {
    private func checkCompatibility(_ mode: String, expected: AgentConnectionStatus) async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let executable = root.appendingPathComponent("codex")
        let fixture = try XCTUnwrap(Bundle(for: AssistantRemainingRequirementsTests.self).url(forResource: "codex-compatibility", withExtension: "py"))
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try mode.write(to: root.appendingPathComponent("codex.mode"), atomically: true, encoding: .utf8)
        let store = try JotBloomStore(dataDirectoryURL: root.appendingPathComponent("data")); defer { store.close() }
        let service = AgentTaskService(store: store)
        let result = await service.check(custom: executable.path)
        XCTAssertEqual(result.status, expected)
        XCTAssertEqual(result.ready, expected == .ready)
        XCTAssertEqual(result.version, "codex-cli 0.0.0-fixture")
        if expected == .unsupported { XCTAssertTrue(result.message.contains("版本不支持")); XCTAssertTrue(result.message.contains("0.0.0-fixture")) }
        let methods = try String(contentsOf: root.appendingPathComponent("codex.requests")).split(separator: "\n")
        XCTAssertTrue(methods.contains("initialize")); XCTAssertFalse(methods.contains("thread/start"))
        XCTAssertTrue(Set(methods).isSubset(of: ["initialize", "initialized", "account/read"]))
        await service.shutdown()
    }
    func testHandshakeFailureIsUnsupportedDuringDetection() async throws { try await checkCompatibility("handshake_error", expected: .unsupported) }
    func testRequiredMethodMissingIsUnsupportedDuringDetection() async throws { try await checkCompatibility("method_missing", expected: .unsupported) }
    func testMissingCriticalFieldsAreUnsupportedDuringDetection() async throws {
        for mode in ["missing_handshake", "missing_account_field", "invalid_account"] { try await checkCompatibility(mode, expected: .unsupported) }
    }
    func testSignedOutAndCompatibleAreDistinctAndExtraFieldsAreIgnored() async throws {
        try await checkCompatibility("signed_out", expected: .signedOut)
        try await checkCompatibility("compatible", expected: .ready)
    }
    func testUnavailableCodexDisablesSuggestedPlanWithoutAutoReenabling() throws {
        let brief = TaskBrief(title: "网页", summary: "做网页", deliverable: "网页", requester: "用户", questions: [], assumptions: [], keywords: [], doneCriteria: "可用", approach: [], needsWork: true, needsCodex: true, needsNetwork: false)
        for status in [AgentConnectionStatus.notFound, .signedOut, .unsupported, .unavailable, .unchecked] {
            var plan = AssistantPlan(brief: brief, reminders: [], materials: [], outputDirectory: "/unused")
            plan.allowCodex = true
            plan.restrictCodex(to: .init(status: status)); XCTAssertFalse(plan.allowCodex)
            plan.restrictCodex(to: .init(ready: true)); XCTAssertFalse(plan.allowCodex)
        }
    }
    private func approval(_ params: [String: ToolValue], method: String = "item/commandExecution/requestApproval", detail: String = "") throws -> AssistantRuntimeQuestion {
        try XCTUnwrap(AgentApprovalPolicy.question(method: method, params: .object(params), id: .number(1), detail: detail))
    }
    func testApprovalReadCountAndReasonAreLocalAndCommandStaysInDetails() throws {
        let actions: [ToolValue] = ["a.txt", "b.txt", "c.txt"].map { .object(["type": .string("read"), "path": .string("/fixture/" + $0)]) }
        let result = try approval(["commandActions": .array(actions), "reason": .string("核对三个输入文件"), "command": .string("RAW_COMMAND_NOT_IN_SUMMARY")])
        XCTAssertTrue(result.text.contains("读取 3 个文件")); XCTAssertTrue(result.text.contains("原因：核对三个输入文件"))
        XCTAssertFalse(result.text.contains("RAW_COMMAND_NOT_IN_SUMMARY")); XCTAssertTrue(result.agent!.detail.contains("RAW_COMMAND_NOT_IN_SUMMARY"))
        let repeated = try approval(["commandActions": .array([actions[0], actions[0]])])
        XCTAssertTrue(repeated.text.contains("读取《a.txt》")); XCTAssertFalse(repeated.text.contains("2 个文件"))
    }
    func testApprovalDirectorySearchAndNetworkExplainWhatWillHappen() throws {
        let search = try approval(["commandActions": .array([.object(["type": .string("listFiles"), "path": .string("/fixture/资料")]), .object(["type": .string("search"), "query": .string("预算"), "path": .string("/fixture/资料")])])])
        XCTAssertTrue(search.text.contains("查看《资料》中的文件列表")); XCTAssertTrue(search.text.contains("搜索文件内容“预算”"))
        let network = try approval(["networkApprovalContext": .object(["host": .string("developer.apple.com"), "protocol": .string("https")]), "reason": .string("读取官方说明")])
        XCTAssertTrue(network.text.contains("访问 developer.apple.com")); XCTAssertTrue(network.text.contains("原因：读取官方说明"))
        XCTAssertFalse(network.agent!.allowsSession)
    }
    func testApprovalFileNamesAndUnknownOperationsHaveHonestFallbacks() throws {
        let detail: ToolValue = .object(["type": .string("fileChange"), "changes": .array([.object(["path": .string("/fixture/方案.md")])])])
        let file = try approval(["reason": .string("补充验收说明")], method: "item/fileChange/requestApproval", detail: detail.json)
        XCTAssertTrue(file.text.contains("想修改《方案.md》")); XCTAssertTrue(file.text.contains("原因：补充验收说明"))
        XCTAssertTrue(try approval([:], method: "item/fileChange/requestApproval").text.contains("想修改文件"))
        XCTAssertTrue(try approval(["command": .string("anything")]).text.contains("想运行一个命令"))
        let mixed = try approval(["commandActions": .array([.object(["type": .string("read"), "path": .string("/fixture/说明.md")]), .object(["type": .string("futureAction")])])])
        XCTAssertTrue(mixed.text.contains("读取《说明.md》")); XCTAssertTrue(mixed.text.contains("无法识别具体用途"))
    }
}

extension AssistantExecutionTests {
    func testCodexGetsFilePathsOnlyWhileLibraryBodiesStillArrive() async throws {
        let file = root.appendingPathComponent("only-path.txt")
        try "FILE_BODY_MUST_NOT_BE_SENT".write(to: file, atomically: true, encoding: .utf8)
        let note = try await store.saveExternalInspiration("LIBRARY_BODY_MUST_BE_SENT", timestampUTCms: 1)
        let material = AssistantAttachment(kind: .inspiration, reference: String(note.id), title: "资料")
        let savedPrompt = try await store.saveInputPrompt(content: "PROMPT_BODY_MUST_BE_SENT", token: UUID().uuidString, timestamp: 2)
        let promptMaterial = AssistantAttachment(kind: .prompt, reference: String(savedPrompt.id), title: "提示词")
        let task = try await prepared(materials: [.file(file), material, promptMaterial], allowCodex: true)
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        let connector = FixtureAgentConnector(), service = AgentTaskService(store: store, connector: connector)
        await service.configure(changed: { _ in }, owned: { _ in }); await service.configurePath("fixture")
        let run = Task { try await service.run(id: task.id, instruction: "按资料处理") }
        for _ in 0..<400 { if await connector.snapshot().0 == 1 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let prompts = await connector.prompts(), prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains(file.path)); XCTAssertFalse(prompt.contains("FILE_BODY_MUST_NOT_BE_SENT"))
        XCTAssertTrue(prompt.contains("LIBRARY_BODY_MUST_BE_SENT"))
        XCTAssertTrue(prompt.contains("PROMPT_BODY_MUST_BE_SENT"))
        await connector.emit("turn/completed", values: ["turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        _ = try await run.value; await service.shutdown()
        let guarded = AssistantPrompts.assignment(task: task, state: .init(), instruction: "检查", materials: [(.file(file), "EVEN_IF_A_CALLER_PASSES_BODY")])
        XCTAssertFalse(guarded.contains("EVEN_IF_A_CALLER_PASSES_BODY"))
    }
    func testAssignmentSeparatesDeliverablesExistingEditsAndNewProjectFiles() async throws {
        var task = try await prepared(allowCodex: true)
        task.scope?.workingDirectory = root.appendingPathComponent("project").path
        let prompt = AssistantPrompts.assignment(task: task, state: .init(), instruction: "继续", materials: [])
        XCTAssertTrue(prompt.contains("交付物放结果文件夹"))
        XCTAssertTrue(prompt.contains("现有文件原地修改"))
        XCTAssertTrue(prompt.contains("项目运行需要的新文件放工作文件夹：" + task.scope!.workingDirectory!))
        task.scope?.workingDirectory = nil
        let isolated = AssistantPrompts.assignment(task: task, state: .init(), instruction: "继续", materials: [])
        XCTAssertTrue(isolated.contains("未选择工作文件夹，所有新文件放结果文件夹，不修改其他项目"))
    }
    func testFiveTextResultTypesCanBeCopiedAndSavedVerbatimWithoutChangingWriteTools() async throws {
        let task = try await prepared(allowCodex: true)
        let files = try AssistantResultFiles(directory: task.scope!.outputDirectory)
        let body = "\n  <html>原文 &amp; \\\"</html>\r\n" + String(repeating: "内容", count: 11_000) + "\n"
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        try await store.finishExecution(id: task.id, summary: "fixture")
        let coordinator = AssistantCoordinator(store: store); await coordinator.start()
        for ext in ["md", "txt", "csv", "html", "json"] {
            let name = "原文." + ext
            XCTAssertTrue(AssistantResultFiles.supportsTextActions(name))
            try body.write(toFile: files.directory + "/" + name, atomically: true, encoding: .utf8)
            let read = try await coordinator.readExecutionResult(task.id, name: name); XCTAssertEqual(read, body)
            try await coordinator.saveExecutionResult(task.id, name: name)
        }
        let bodies = try store.performSync { db -> [String] in
            let rows = try db.prepare("SELECT body FROM inspirations", operation: "fixture_verbatim"); var values: [String] = []
            while try rows.stepRow() { values.append(rows.text(at: 0)) }; return values
        }
        XCTAssertEqual(bodies, Array(repeating: body, count: 5))
        for name in ["image.png", "code.swift", "data.pdf", "../outside.html"] {
            XCTAssertFalse(AssistantResultFiles.supportsTextActions(name))
            do { _ = try await coordinator.readExecutionResult(task.id, name: name); XCTFail("Unexpected text access") } catch {}
        }
        XCTAssertThrowsError(try files.write("not-a-new-tool.html", content: "x", mode: "create"))
        await coordinator.pauseAndDrain()
    }
}
