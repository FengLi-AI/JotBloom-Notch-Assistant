import XCTest
@testable import JotBloomCore

@MainActor
final class AssistantTests: XCTestCase {
    private var directory: URL!
    private var store: JotBloomStore!
    override func setUp() async throws { directory = try TestTemporaryDirectory.make(); store = try JotBloomStore(dataDirectoryURL: directory) }
    override func tearDown() async throws { store.close(); TestTemporaryDirectory.remove(directory) }
    private func completedChat() async throws -> ChatTurn {
        var turn = try await store.submitChat("用户的原始要求", token: "original-turn", source: .aiChat)
        turn.answer = "助手的建议，不能作为用户指令"; turn.status = .complete; try await store.updateChat(turn); return turn
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Timed out"); throw AssistantError.unavailable
    }
    func testConversionUsesOriginalInputAndNeverAddsAChatMessage() async throws {
        let turn = try await completedChat()
        let coordinator = AssistantCoordinator(store: store); coordinator.modelConfigured = { true }; await coordinator.start()
        let model = AssistantViewModel(coordinator: coordinator)
        model.convert(turn); model.convert(turn)
        try await wait { model.savingTurns.isEmpty }
        let saved = try XCTUnwrap(model.tasks.first)
        XCTAssertEqual(saved.rawInput, turn.user); XCTAssertEqual(saved.status, .received)
        XCTAssertEqual(model.tasks.count, 1); XCTAssertEqual(model.links[turn.token]?.taskID, saved.id)
        let again = try await coordinator.receive(input: turn.user, source: .chat, turn: turn)
        XCTAssertEqual(again.id, saved.id)
        let page = try await store.chatPage(); XCTAssertEqual(page.turns, [turn])
        let materials = try await store.assistantMaterials(taskID: saved.id)
        XCTAssertEqual(materials.first?.kind, .chat)
        let selected = try store.performSync { db in
            let row = try db.prepare("SELECT selected FROM assistant_materials", operation: "test"); _ = try row.stepRow(); return row.int64(at: 0)
        }
        XCTAssertEqual(selected, 0, "Chat context requires an explicit selection later")
    }
    func testTaskSurvivesChatDeletionAndReopen() async throws {
        let turn = try await completedChat()
        let task = try await store.createAssistantTask(id: "t", input: turn.user, source: .chat, attachments: [], session: turn.session, turn: turn.token)
        try await store.deleteChat(turn.session)
        store.close(); store = try JotBloomStore(dataDirectoryURL: directory)
        let loaded = try await store.assistantTask(id: task.id)
        XCTAssertEqual(loaded, task)
        let links = try await store.assistantTaskLinks(); XCTAssertEqual(links.first?.taskID, task.id)
    }
    func testDeleteCascadesTaskInternalsButKeepsTombstoneAndResultFiles() async throws {
        let turn = try await completedChat()
        let result = directory.appendingPathComponent("result.txt"); try Data("keep".utf8).write(to: result)
        _ = try await store.createAssistantTask(id: "t", input: turn.user, source: .chat, attachments: [.file(result)], session: turn.session, turn: turn.token)
        try store.performSync { db in
            try db.execute("""
                INSERT INTO assistant_task_steps(task_id,step_index,tool,args_json,decision,state,created_at_ms) VALUES('t',0,'save_result','{}','allow','done',1);
                INSERT INTO assistant_questions(id,task_id,kind,payload_json,created_at_ms) VALUES('q','t','clarify','{}',1);
                INSERT INTO assistant_reminders(id,task_id,fire_at_ms,state) VALUES('r','t',1,'pending');
                """, operation: "test")
        }
        do { try await store.deleteAssistantTask(id: "t"); XCTFail("Cannot delete an unfinished task") } catch { XCTAssertEqual(error as? AssistantError, .invalidTransition) }
        try await store.transitionAssistantTask(id: "t", event: .failed, text: "fixture failure")
        try await store.deleteAssistantTask(id: "t")
        let tasks = try await store.assistantTasks(); XCTAssertTrue(tasks.isEmpty)
        let links = try await store.assistantTaskLinks(); XCTAssertEqual(links.count, 1); XCTAssertNil(links[0].taskID)
        for table in ["assistant_task_events", "assistant_task_steps", "assistant_questions", "assistant_reminders", "assistant_materials"] {
            let count = try store.performSync { db in
                let row = try db.prepare("SELECT COUNT(*) FROM \(table)", operation: "test"); _ = try row.stepRow(); return row.int64(at: 0)
            }; XCTAssertEqual(count, 0, table)
        }
        XCTAssertEqual(try String(contentsOf: result), "keep")
        let page = try await store.chatPage(); XCTAssertEqual(page.turns, [turn])
    }
    func testMissingModelPersistsDropAndGroupsForAttention() async throws {
        let coordinator = AssistantCoordinator(store: store); await coordinator.start()
        let task = try await coordinator.receive(input: "给我记住这件事", source: .notchText)
        XCTAssertEqual(task.status, .waitingUser); XCTAssertEqual(task.errorCode, "modelNotConfigured")
        XCTAssertEqual(coordinator.entryTitle, "1 件等你处理")
        await coordinator.pauseAndDrain()
        do { _ = try await coordinator.receive(input: "maintenance", source: .notchText); XCTFail() } catch { XCTAssertEqual(error as? AssistantError, .unavailable) }
        coordinator.resume(); try await coordinator.cancel(id: task.id)
        XCTAssertEqual(coordinator.entryTitle, "任务"); XCTAssertNil(coordinator.tasks.first?.status.group)
    }
    func testCrashRecoveryKeepsPartialWorkAndInvalidatesOldApprovalID() async throws {
        _ = try await store.createAssistantTask(id: "t", input: "恢复", source: .notchText, attachments: [])
        for event: TaskTransitionEvent in [.beginUnderstanding, .understoodWithPlan, .userConfirmedWork, .executionStarted] {
            try await store.transitionAssistantTask(id: "t", event: event, text: "fixture transition")
        }
        try store.performSync { db in
            try db.execute("INSERT INTO assistant_task_steps(task_id,step_index,tool,args_json,decision,state,result_text,created_at_ms) VALUES('t',0,'read_file','{}','allow','running','partial',1); INSERT INTO assistant_questions(id,task_id,kind,payload_json,rpc_request_id,created_at_ms) VALUES('q','t','approval','{}','old-rpc',1)", operation: "test")
        }
        store.close(); store = try JotBloomStore(dataDirectoryURL: directory)
        try await store.recoverAssistantTasks(); try await store.recoverAssistantTasks()
        let task = try await store.assistantTask(id: "t"); XCTAssertEqual(task?.status, .interrupted)
        let events = try await store.assistantEvents(taskID: "t"); XCTAssertEqual(events.filter { $0.kind == "interrupted" }.count, 1)
        try store.performSync { db in
            let step = try db.prepare("SELECT state,result_text FROM assistant_task_steps", operation: "test"); _ = try step.stepRow()
            XCTAssertEqual(step.text(at: 0), "unknown"); XCTAssertEqual(step.text(at: 1), "partial")
            let question = try db.prepare("SELECT rpc_request_id,answer_json FROM assistant_questions", operation: "test"); _ = try question.stepRow()
            XCTAssertTrue(question.isNull(at: 0)); XCTAssertTrue(question.isNull(at: 1))
        }
    }
    func testAttachmentOnlyDraftSurvivesNewChatSwitchAndRestart() async throws {
        let session = try await store.currentChatIdentity()
        let files: [AssistantAttachment] = [.file(directory.appendingPathComponent("not-read.txt"))]
        try store.saveAssistantDraftAttachments(files, session: session)
        try await store.newChat(); let next = try await store.currentChatIdentity(); XCTAssertNotEqual(session, next)
        let history = try await store.chatSessions(); XCTAssertTrue(history.contains { $0.id == session })
        try store.saveAssistantDraftAttachments([.init(kind: .inspiration, reference: "1", title: "灵感")], session: next)
        try await store.selectChat(session)
        store.close(); store = try JotBloomStore(dataDirectoryURL: directory)
        XCTAssertEqual(try store.assistantDraftAttachments(session: session), files)
        XCTAssertEqual(try store.assistantDraftAttachments(session: next).count, 1)
        try await store.deleteChat(session)
        XCTAssertTrue(try store.assistantDraftAttachments(session: session).isEmpty)
    }
    func testAttachmentSendCreatesTaskAndReceiptAtomicallyWithoutNetworkOrKey() async throws {
        let credentials = AssistantCredentialsProbe(), transport = AssistantTransportProbe()
        let chat = ChatViewModel(store: store, credentials: credentials, configuration: { .init(baseURL: "https://example.invalid", model: "fixture") }, transport: transport)
        let coordinator = AssistantCoordinator(store: store); await coordinator.start(); await chat.start()
        chat.onSubmitTask = { input, attachments, token, session, prompt in
            try await coordinator.submitChat(input: input, attachments: attachments, token: token, session: session, systemPrompt: prompt)
        }
        let file = AssistantAttachment.file(directory.appendingPathComponent("reference.txt"))
        chat.draft = "整理资料"; chat.addAttachments([file, file]); XCTAssertEqual(chat.attachments.count, 1)
        chat.send(); try await wait { !chat.busy }
        XCTAssertTrue(chat.draft.isEmpty); XCTAssertTrue(chat.attachments.isEmpty)
        XCTAssertEqual(chat.turns.count, 1); XCTAssertEqual(chat.turns[0].answer, "已转为任务。")
        XCTAssertEqual(coordinator.tasks.count, 1)
        let calls = await transport.calls, reads = await credentials.reads; XCTAssertEqual(calls, 0); XCTAssertEqual(reads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.reference), "Only a reference is stored")
        try store.persistDraftSynchronously(kind: .aiChat, content: "下一轮草稿", updatedAtUTCms: 2)
        try store.saveAssistantDraftAttachments([file], session: chat.currentSession)
        let again = try await coordinator.submitChat(input: "不能覆盖原要求", attachments: [file], token: chat.turns[0].token, session: chat.currentSession, systemPrompt: "fixture")
        XCTAssertEqual(again, chat.turns[0]); XCTAssertEqual(coordinator.tasks.count, 1)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "下一轮草稿")
        XCTAssertEqual(try store.assistantDraftAttachments(session: chat.currentSession), [file])
    }
    func testUnconfiguredOrFailedAttachmentSendKeepsDraft() async throws {
        var configuration = ModelConfiguration()
        let chat = ChatViewModel(store: store, credentials: AssistantCredentialsProbe(), configuration: { configuration }, transport: AssistantTransportProbe())
        await chat.start(); chat.draft = "未发送要求"
        let file = AssistantAttachment.file(directory.appendingPathComponent("x.txt")); chat.addAttachments([file])
        chat.send(); XCTAssertEqual(chat.draft, "未发送要求"); XCTAssertEqual(chat.attachments, [file])
        configuration = .init(baseURL: "https://example.invalid", model: "fixture")
        chat.onSubmitTask = { _, _, _, _, _ in throw AssistantError.unavailable }
        chat.send(); try await wait { !chat.busy }
        XCTAssertEqual(chat.draft, "未发送要求"); XCTAssertEqual(chat.attachments, [file]); XCTAssertTrue(chat.turns.isEmpty)
        XCTAssertEqual(try store.assistantDraftAttachments(session: chat.currentSession), [file])
    }
    func testReceiptFailureRollsBackTaskAndRetainsBothDrafts() async throws {
        let session = try await store.currentChatIdentity()
        let file = AssistantAttachment.file(directory.appendingPathComponent("x.txt"))
        try store.saveAssistantDraftAttachments([file], session: session)
        try store.persistDraftSynchronously(kind: .aiChat, content: "草稿", updatedAtUTCms: 1)
        try store.performSync { try $0.execute("CREATE TRIGGER fail_receipt BEFORE INSERT ON chat_messages BEGIN SELECT RAISE(ABORT,'fixture'); END", operation: "test") }
        do { _ = try await store.submitAssistantChat(input: "草稿", attachments: [file], token: "once", expectedSession: session, systemPrompt: "test"); XCTFail() } catch {}
        let tasks = try await store.assistantTasks(); XCTAssertTrue(tasks.isEmpty)
        let links = try await store.assistantTaskLinks(); XCTAssertTrue(links.isEmpty)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "草稿")
        XCTAssertEqual(try store.assistantDraftAttachments(session: session), [file])
    }
    func testMovingDataDirectoryIncludesTasksLinksAndAttachments() async throws {
        let turn = try await completedChat()
        _ = try await store.createAssistantTask(id: "t", input: turn.user, source: .chat, attachments: [], session: turn.session, turn: turn.token)
        try store.saveAssistantDraftAttachments([.file(directory.appendingPathComponent("x.txt"))], session: turn.session)
        let parent = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(parent) }
        let target = try DataDirectoryMigration().migrate(store: store, parent: parent, location: DataLocationStore(controlDirectory: directory))
        let moved = try JotBloomStore(dataDirectoryURL: target); defer { moved.close() }
        XCTAssertEqual(try moved.migrationRecordCounts(), try store.migrationRecordCounts())
        let tasks = try await moved.assistantTasks(), links = try await moved.assistantTaskLinks()
        XCTAssertEqual(tasks.first?.id, "t"); XCTAssertEqual(links.first?.taskID, "t")
        XCTAssertEqual(try moved.assistantDraftAttachments(session: turn.session).count, 1)
    }
    func testInvalidTransitionDoesNotChangeRecordOrAppendEvent() async throws {
        let task = try await store.createAssistantTask(id: "t", input: "只保存", source: .notchText, attachments: [])
        do { try await store.transitionAssistantTask(id: "t", event: .executionStarted, text: "must not execute"); XCTFail() } catch { XCTAssertEqual(error as? AssistantError, .invalidTransition) }
        let after = try await store.assistantTask(id: "t"), events = try await store.assistantEvents(taskID: "t")
        XCTAssertEqual(after, task); XCTAssertEqual(events.count, 1)
    }
}

final class AssistantTransitionTests: XCTestCase {
    func testOnlyConfirmedPlanCanEnterWorkQueue() throws {
        for status in [TaskStatus.received, .understanding, .needsInfo, .scheduled, .completed, .failed, .cancelled] {
            XCTAssertThrowsError(try TaskTransition.next(from: status, event: .executionStarted))
            XCTAssertThrowsError(try TaskTransition.next(from: status, event: .userConfirmedWork))
        }
        XCTAssertEqual(try TaskTransition.next(from: .planReady, event: .userConfirmedWork), .queued)
        XCTAssertEqual(try TaskTransition.next(from: .queued, event: .executionStarted), .running)
        XCTAssertEqual(try TaskTransition.next(from: .understanding, event: .understoodReminder), .scheduled)
        for terminal in [TaskStatus.completed, .failed, .cancelled] {
            for event in TaskTransitionEvent.allCases {
                if terminal == .failed && event == .retryUnderstanding {
                    XCTAssertEqual(try TaskTransition.next(from: terminal, event: event), .understanding)
                } else { XCTAssertThrowsError(try TaskTransition.next(from: terminal, event: event)) }
            }
        }
    }
    func testDragSequenceCannotSaveToBothDestinationsOrDuplicate() {
        var session = AssistantDropSession()
        XCTAssertTrue(session.begin(1)); XCTAssertTrue(session.begin(1))
        XCTAssertTrue(session.commit(1, to: .assistant)); XCTAssertFalse(session.commit(1, to: .notch))
        XCTAssertFalse(session.begin(1)); XCTAssertEqual(session.destination(for: 1), .assistant)
        XCTAssertTrue(session.begin(2)); session.cancel(); XCTAssertFalse(session.commit(2, to: .assistant))
        XCTAssertTrue(session.begin(3)); XCTAssertTrue(session.commit(3, to: .notch)); XCTAssertFalse(session.commit(3, to: .assistant))
    }
    func testTabIdentityRemainsCompatibleWithSavedPreferences() {
        XCTAssertEqual(PanelSlot.chat.rawValue, "chat"); XCTAssertEqual(PanelSlot.chat.title, "助手")
    }
}

private actor AssistantCredentialsProbe: CredentialStoring {
    var reads = 0
    func read(_ slot: ModelSlot) -> String? { reads += 1; return nil }
    func write(_ secret: String, slot: ModelSlot) {}
    func remove(_ slot: ModelSlot) {}
}
private actor AssistantTransportProbe: ChatStreamingTransport {
    var calls = 0
    func stream(_ request: URLRequest, onText: @escaping @Sendable (String) async throws -> Void) async throws -> ChatStatus {
        calls += 1; throw URLError(.badURL)
    }
}
