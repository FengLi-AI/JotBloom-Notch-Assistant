import XCTest
@testable import JotBloomCore

@MainActor
final class ChatTests: XCTestCase {
    private var directory: URL!
    private var store: JotBloomStore!
    override func setUp() async throws { directory = try TestTemporaryDirectory.make(); store = try JotBloomStore(dataDirectoryURL: directory) }
    override func tearDown() async throws { store.close(); TestTemporaryDirectory.remove(directory) }
    private func completed(_ text: String = "问题") async throws -> ChatTurn {
        var row = try await store.submitChat(text, token: UUID().uuidString, source: .aiChat)
        row.answer = "完整回答"; row.status = .complete; try await store.updateChat(row); return row
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Timed out waiting for isolated fixture"); throw ChatError.busy
    }
    func testAtomicSubmissionClearsOnlySourceAndIsIdempotent() async throws {
        try store.persistDraftSynchronously(kind: .inspiration, content: "灵感草稿", updatedAtUTCms: 1)
        try store.persistDraftSynchronously(kind: .aiChat, content: "聊天草稿", updatedAtUTCms: 1)
        let row = try await store.submitChat("灵感草稿", token: "once", source: .inspiration)
        let duplicate = try await store.submitChat("灵感草稿", token: "once", source: .inspiration)
        let page = try await store.chatPage()
        XCTAssertEqual(row, duplicate); XCTAssertEqual(page.turns.count, 1)
        XCTAssertNil(try store.loadDraftSynchronously(kind: .inspiration))
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "聊天草稿")
        do { _ = try await store.submitChat("重复并发", token: "second", source: .aiChat); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .busy) }
    }
    func testRecoveryKeepsPartialAndNeverAddsItToContext() async throws {
        _ = try await completed()
        var partial = try await store.submitChat("第二问", token: "partial", source: .aiChat)
        partial.answer = "已收到一半"; partial.status = .streaming; try await store.updateChat(partial)
        store.close(); store = try JotBloomStore(dataDirectoryURL: directory)
        let page = try await store.chatPage(recover: true), context = try await store.chatContext()
        XCTAssertEqual(page.turns.last?.status, .interrupted); XCTAssertEqual(page.turns.last?.answer, "已收到一半")
        XCTAssertEqual(context.count, 1)
    }
    func testRetryReusesTurnAndRejectsLateOldAttempt() async throws {
        var row = try await store.submitChat("问题", token: "one", source: .aiChat)
        row.answer = "旧片段"; row.status = .stopped; try await store.updateChat(row)
        var retry = try await store.retryChat(row)
        XCTAssertEqual(retry.id, row.id); XCTAssertEqual(retry.answer, "旧片段"); XCTAssertNotEqual(retry.attempt, row.attempt)
        row.status = .complete
        do { try await store.updateChat(row); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .stale) }
        retry.answer = "新完整回答"; retry.status = .complete; try await store.updateChat(retry)
        let page = try await store.chatPage(); XCTAssertEqual(page.turns.count, 1); XCTAssertEqual(page.turns[0].answer, retry.answer)
    }
    func testNewConversationArchivesChatAndRejectsOldWrite() async throws {
        let row = try await completed()
        try store.persistDraftSynchronously(kind: .inspiration, content: "保留", updatedAtUTCms: 1)
        try store.persistDraftSynchronously(kind: .aiChat, content: "清空", updatedAtUTCms: 1)
        try await store.newChat()
        let page = try await store.chatPage(); XCTAssertTrue(page.turns.isEmpty)
        XCTAssertNil(try store.loadDraftSynchronously(kind: .aiChat)); XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "保留")
        do { try await store.updateChat(row); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .stale) }
        try await store.selectChat(row.session)
        let restored = try await store.chatPage()
        XCTAssertEqual(restored.turns, [row])
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "清空")
    }
    func testChatPagesFiftyWithoutOverlap() async throws {
        for index in 0..<103 { _ = try await completed("问题\(index)") }
        let first = try await store.chatPage(), second = try await store.chatPage(before: first.turns.first!.id)
        let third = try await store.chatPage(before: second.turns.first!.id)
        XCTAssertEqual(first.turns.count, 50); XCTAssertEqual(second.turns.count, 50); XCTAssertEqual(third.turns.count, 3)
        XCTAssertTrue(first.hasMore); XCTAssertFalse(third.hasMore)
        XCTAssertEqual(Set((first.turns + second.turns + third.turns).map(\.id)).count, 103)
    }
    func testV4UpgradeHasRecoverableBackupAndRejectsFuture() throws {
        let oldDirectory = directory.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let url = oldDirectory.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let db = try SQLiteConnection(databaseURL: url)
        try DatabaseMigrator.createVersionTwo(db); try DatabaseMigrator.migrateVersionTwoToThree(db)
        try DatabaseMigrator.migrateVersionThreeToFour(db)
        try db.execute("INSERT INTO drafts(kind,content,updated_at_utc_ms) VALUES('ai_chat','升级前草稿',1)", operation: "fixture")
        db.close()
        let upgraded = try JotBloomStore(dataDirectoryURL: oldDirectory); defer { upgraded.close() }
        XCTAssertEqual(try upgraded.schemaVersionSynchronously(), 7)
        XCTAssertEqual(try upgraded.loadDraftSynchronously(kind: .aiChat)?.content, "升级前草稿")
        let backup = try SQLiteConnection(databaseURL: url.appendingPathExtension("bak-v4"), readOnly: true); defer { backup.close() }
        XCTAssertEqual(try backup.userVersion(), 4)
    }
    func testRequestBudgetKeepsThreeAndUsesMainChatOptions() throws {
        let row = ChatTurn(id: 1, session: "s", token: "t", attempt: "a", user: String(repeating: "字", count: 1100), answer: "答", timestamp: 1, status: .complete)
        let messages = try ChatContext.messages(history: Array(repeating: row, count: 10), input: "问题")
        XCTAssertGreaterThanOrEqual(messages.count, 8); XCTAssertLessThan(messages.count, 22)
        XCTAssertThrowsError(try ChatContext.messages(history: Array(repeating: row, count: 3), input: String(repeating: "字", count: 8000)))
        let request = try ChatContext.request(configuration: ModelConfiguration(baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash"), key: "fixture-not-a-key", messages: messages)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true); XCTAssertEqual(json["max_tokens"] as? Int, 2048)
        XCTAssertEqual(json["temperature"] as? Double, 0.8); XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        let other = try ChatContext.request(configuration: ModelConfiguration(baseURL: "https://example.com/v1", model: "deepseek-v4-flash"), key: "fixture", messages: messages)
        let otherJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: other.httpBody!) as? [String: Any]); XCTAssertNil(otherJSON["thinking"])
    }
    func testNoKeyBrowseDoesNotReadAndFailedSendRetainsDraft() async throws {
        let credentials = ChatCredentialsFixture(key: nil)
        let transport = ChatTransportFixture(mode: .success)
        let model = ChatViewModel(store: store, credentials: credentials, configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
        await model.start(); model.focus()
        let browsed = await credentials.reads; XCTAssertEqual(browsed, 0)
        model.draft = "保留草稿"; model.send(); try await wait { !model.busy }
        XCTAssertEqual(model.draft, "保留草稿"); XCTAssertTrue(model.turns.isEmpty)
        let requests = await transport.calls; XCTAssertEqual(requests, 0)
    }
    func testSendStreamsAndPreservesNewDraft() async throws {
        let transport = ChatTransportFixture(mode: .slowSuccess)
        let model = ChatViewModel(store: store, credentials: ChatCredentialsFixture(key: "fixture"), configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
        await model.start(); model.draft = "已发送"; model.send()
        try await wait { model.turns.last?.answer == "第一段" }
        XCTAssertTrue(model.busy); model.draft = "下一条草稿"
        try await wait { !model.busy }
        XCTAssertEqual(model.turns.last?.answer, "第一段第二段"); XCTAssertEqual(model.turns.last?.status, .complete)
        XCTAssertEqual(model.draft, "下一条草稿"); try model.flushDraft()
        let restored = try await store.chatPage(); XCTAssertEqual(restored.turns.last?.answer, "第一段第二段")
    }
    func testStopFlushesPartialAndRetryReplacesWithoutDuplicateUser() async throws {
        let transport = ChatTransportFixture(mode: .slowSuccess)
        let model = ChatViewModel(store: store, credentials: ChatCredentialsFixture(key: "fixture"), configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
        await model.start(); model.draft = "问题"; model.send(); try await wait { model.turns.last?.answer == "第一段" }
        model.stop(); try await wait { !model.busy }
        XCTAssertEqual(model.turns.last?.status, .stopped)
        var page = try await store.chatPage(); XCTAssertEqual(page.turns.last?.answer, "第一段")
        model.retry(); try await wait { !model.busy }
        page = try await store.chatPage(); XCTAssertEqual(page.turns.count, 1); XCTAssertEqual(page.turns.last?.answer, "第一段第二段")
    }
    func testNetworkRetriesOnlyBeforePartialAndNeverOnAuthenticationFailure() async throws {
        for mode in [ChatTransportFixture.Mode.failFirst, .partialFailure, .unauthorized] {
            try await store.newChat()
            let transport = ChatTransportFixture(mode: mode)
            let model = ChatViewModel(store: store, credentials: ChatCredentialsFixture(key: "fixture"), configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
            await model.start(); model.draft = "问题"; model.send(); try await wait { !model.busy }
            let calls = await transport.calls
            XCTAssertEqual(calls, mode == .failFirst ? 2 : 1)
            XCTAssertEqual(model.turns.last?.status, mode == .failFirst ? .complete : .failed)
            if mode == .partialFailure { XCTAssertEqual(model.turns.last?.answer, "第一段") }
        }
    }
    func testStorageFailureKeepsInputAndDoesNotRequestNetwork() async throws {
        let transport = ChatTransportFixture(mode: .success)
        let model = ChatViewModel(store: store, credentials: ChatCredentialsFixture(key: "fixture"), configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
        await model.start(); store.close(); model.draft = "尚未保存"; model.send(); try await wait { !model.busy }
        XCTAssertEqual(model.draft, "尚未保存"); XCTAssertTrue(model.turns.isEmpty)
        let calls = await transport.calls; XCTAssertEqual(calls, 0)
    }
    func testLateAuthorizationAfterCancelNeverCommitsOrSends() async throws {
        let credentials = ChatDelayedCredentials(), transport = ChatTransportFixture(mode: .success)
        let model = ChatViewModel(store: store, credentials: credentials, configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
        var protections: [Bool] = []; model.onSystemInteraction = { protections.append($0) }
        await model.start(); model.draft = "授权取消保留"; model.send(); try await wait { model.authorizing }
        model.cancelAuthorization(); await credentials.resolve(); try await wait { !model.busy }
        XCTAssertEqual(model.draft, "授权取消保留"); XCTAssertTrue(model.turns.isEmpty); XCTAssertEqual(protections, [true, false])
        let calls = await transport.calls; XCTAssertEqual(calls, 0)
    }
    func testDeniedDailySendsKeepDraftAndNeverFallBackToAuthorization() async throws {
        let credentials = ChatDeniedCredentials(), transport = ChatTransportFixture(mode: .success)
        let model = ChatViewModel(store: store, credentials: credentials, configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
        await model.start(); model.draft = "保留我的输入"
        for _ in 0..<3 { model.send(); try await wait { !model.busy } }
        XCTAssertEqual(model.draft, "保留我的输入"); XCTAssertTrue(model.turns.isEmpty); XCTAssertTrue(model.needsCredentialHelp)
        let interactive = await credentials.interactiveCalls, calls = await transport.calls
        XCTAssertEqual(interactive, 0); XCTAssertEqual(calls, 0)
    }
    func testDeniedSummaryKeepsHistoryAndNeverRequestsAuthorization() async throws {
        _ = try await completed()
        let credentials = ChatDeniedCredentials(), transport = ChatTransportFixture(mode: .success)
        let model = ChatViewModel(store: store, credentials: credentials, configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
        await model.start(); model.summarize(); try await wait { !model.busy }
        XCTAssertEqual(model.turns.count, 1); XCTAssertFalse(model.summaryPreview); XCTAssertTrue(model.needsCredentialHelp)
        let interactive = await credentials.interactiveCalls, calls = await transport.calls
        XCTAssertEqual(interactive, 0); XCTAssertEqual(calls, 0)
    }
    func testFinalStorageFailureIsVisibleAndRetrySavesCompletedAnswerAtomically() async throws {
        let transport = ChatTransportFixture(mode: .slowSuccess)
        let model = ChatViewModel(store: store, credentials: ChatCredentialsFixture(key: "fixture"), configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
        await model.start(); model.draft = "保存失败测试"; model.send(); try await wait { model.turns.last?.answer == "第一段" }
        let db = try SQLiteConnection(databaseURL: directory.appendingPathComponent(DataDirectoryResolver.databaseFileName)); defer { db.close() }
        try db.execute("CREATE TRIGGER fixture_fail_chat_touch BEFORE UPDATE ON chat_sessions BEGIN SELECT RAISE(ABORT,'fixture'); END", operation: "fixture_fail")
        try await wait { !model.busy }
        XCTAssertTrue(model.needsStorageRetry); XCTAssertNotNil(model.feedback); XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.turns.last?.status, .complete); XCTAssertEqual(model.turns.last?.answer, "第一段第二段")
        let rolledBack = try await store.chatPage(); XCTAssertEqual(rolledBack.turns.last?.status, .waiting)
        try db.execute("DROP TRIGGER fixture_fail_chat_touch", operation: "fixture_recover")
        model.retryStorage(); try await wait { !model.busy }
        XCTAssertFalse(model.needsStorageRetry)
        let persisted = try await store.chatPage(); XCTAssertEqual(persisted.turns.last?.status, .complete); XCTAssertEqual(persisted.turns.last?.answer, "第一段第二段")
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
    }
    func testABAWhileAuthorizingKeepsNewVersionOfSameDraft() async throws {
        let credentials = ChatDelayedCredentials(), transport = ChatTransportFixture(mode: .success)
        let model = ChatViewModel(store: store, credentials: credentials, configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: transport)
        await model.start(); model.draft = "A"; model.send(); try await wait { model.authorizing }
        model.draft = "B"; model.draft = "A"; await credentials.resolve(); try await wait { !model.busy }
        XCTAssertEqual(model.draft, "A"); XCTAssertEqual(model.turns.count, 1); try model.flushDraft()
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "A")
    }
    func testV5UpgradeRetainsMessagesDraftAndBackup() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let url = root.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let db = try SQLiteConnection(databaseURL: url)
        try DatabaseMigrator.createVersionTwo(db)
        try DatabaseMigrator.migrateVersionTwoToThree(db)
        try DatabaseMigrator.migrateVersionThreeToFour(db)
        try DatabaseMigrator.migrateVersionFourToFive(db)
        try db.execute("""
            INSERT INTO chat_sessions(id,slot,token,updated_at_utc_ms) VALUES(9,1,'old-session',100);
            INSERT INTO chat_messages(id,session_id,role,content,created_at_utc_ms,turn_token,attempt_token,state)
            VALUES(40,9,'user','原问题',99,'turn','attempt','complete'),(41,9,'assistant','原完整回答',100,'turn','attempt','complete');
            INSERT INTO drafts(kind,content,updated_at_utc_ms) VALUES('ai_chat','旧草稿',101);
            """, operation: "v5_fixture")
        db.close()
        let upgraded = try JotBloomStore(dataDirectoryURL: root); defer { upgraded.close() }
        let page = try await upgraded.chatPage()
        XCTAssertEqual(try upgraded.schemaVersionSynchronously(), 7)
        XCTAssertEqual(page.turns.first?.id, 41); XCTAssertEqual(page.turns.first?.session, "old-session")
        XCTAssertEqual(page.turns.first?.answer, "原完整回答")
        XCTAssertEqual(try upgraded.loadDraftSynchronously(kind: .aiChat)?.content, "旧草稿")
        let backup = try SQLiteConnection(databaseURL: URL(fileURLWithPath: url.path + ".bak-v5"), readOnly: true, createIfMissing: false)
        defer { backup.close() }; XCTAssertEqual(try backup.userVersion(), 5)
        try await upgraded.newChat(); try await upgraded.selectChat("old-session")
        let restored = try await upgraded.chatPage()
        XCTAssertEqual(restored.turns, page.turns)
        XCTAssertEqual(try upgraded.loadDraftSynchronously(kind: .aiChat)?.content, "旧草稿")
    }

    func testSessionsIsolateContextDraftsAndPersistSelection() async throws {
        let a = try await completed("A 的问题")
        try store.persistDraftSynchronously(kind: .aiChat, content: "A 草稿", updatedAtUTCms: 1)
        try await store.newChat()
        let b = try await completed("B 的问题")
        try store.persistDraftSynchronously(kind: .aiChat, content: "B 草稿", updatedAtUTCms: 2)
        var context = try await store.chatContext(); XCTAssertEqual(context.map(\.user), ["B 的问题"])
        try await store.selectChat(a.session)
        context = try await store.chatContext(); XCTAssertEqual(context.map(\.user), ["A 的问题"])
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "A 草稿")
        store.close(); store = try JotBloomStore(dataDirectoryURL: directory)
        var sessions = try await store.chatSessions(); XCTAssertEqual(sessions.first(where: \.isCurrent)?.id, a.session)
        try await store.selectChat(b.session)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "B 草稿")
        sessions = try await store.chatSessions(); XCTAssertEqual(sessions.count, 2)
    }

    func testNewEmptyChatIsReusedButDraftOnlySessionIsPreserved() async throws {
        _ = try await store.chatPage()
        let first = try await store.chatSessions()
        let identity = try await store.currentChatIdentity()
        try await store.newChat(); try await store.newChat()
        var sessions = try await store.chatSessions(); XCTAssertEqual(sessions, first)
        try store.persistDraftSynchronously(kind: .aiChat, content: "只写了草稿", updatedAtUTCms: 1)
        try await store.newChat()
        sessions = try await store.chatSessions(); XCTAssertEqual(sessions.count, 1)
        try await store.selectChat(identity)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "只写了草稿")
    }

    func testRenameAndDeleteOnlyTargetWithRecentDraftRestored() async throws {
        let a = try await completed("A")
        try store.persistDraftSynchronously(kind: .aiChat, content: "A 待发送", updatedAtUTCms: 1)
        try await store.newChat(); let b = try await completed("B")
        let initial = try await store.chatSessions()
        try await store.renameChat(a.session, title: "我的旧对话")
        let renamed = try await store.chatSessions()
        XCTAssertEqual(renamed.first(where: { $0.id == a.session })?.title, "我的旧对话")
        XCTAssertEqual(renamed.map(\.timestamp), initial.map(\.timestamp))
        try await store.deleteChat(b.session)
        let page = try await store.chatPage(); XCTAssertEqual(page.turns.map(\.user), ["A"])
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "A 待发送")
        try await store.deleteChat(a.session)
        let empty = try await store.chatPage(); XCTAssertTrue(empty.turns.isEmpty)
        let sessions = try await store.chatSessions(); XCTAssertTrue(sessions.isEmpty)
    }

    func testSwitchFailureRollsBackSessionAndBothDrafts() async throws {
        let a = try await completed("A")
        try store.persistDraftSynchronously(kind: .aiChat, content: "A 草稿", updatedAtUTCms: 1)
        try await store.newChat(); _ = try await completed("B")
        try store.persistDraftSynchronously(kind: .aiChat, content: "B 草稿", updatedAtUTCms: 2)
        let db = try SQLiteConnection(databaseURL: directory.appendingPathComponent(DataDirectoryResolver.databaseFileName)); defer { db.close() }
        try db.execute("CREATE TRIGGER fail_switch BEFORE UPDATE OF slot ON chat_sessions WHEN NEW.slot=1 BEGIN SELECT RAISE(ABORT,'fixture'); END", operation: "switch_failure")
        do { try await store.selectChat(a.session); XCTFail() } catch {}
        let page = try await store.chatPage(); XCTAssertEqual(page.turns.first?.user, "B")
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "B 草稿")
        try db.execute("DROP TRIGGER fail_switch", operation: "recover_switch")
        try await store.selectChat(a.session)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "A 草稿")
    }

    func testActiveChatBlocksSwitchDeleteAndNewUntilStopped() async throws {
        let a = try await completed("A")
        try await store.newChat()
        var b = try await store.submitChat("B", token: "b", source: .aiChat)
        do { try await store.selectChat(a.session); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .busy) }
        do { try await store.deleteChat(a.session); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .busy) }
        do { try await store.newChat(); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .busy) }
        b.status = .stopped; try await store.updateChat(b)
        try await store.selectChat(a.session)
        do { _ = try await store.retryChat(b); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .stale) }
        try await store.selectChat(b.session)
        let retry = try await store.retryChat(b); XCTAssertEqual(retry.session, b.session)
    }

    func testViewModelNewAndHistoryDoNotRequestAIAndDeleteRequiresConfirmation() async throws {
        _ = try await completed("保留的对话")
        let transport = ChatTransportFixture(mode: .success)
        let model = ChatViewModel(store: store, credentials: ChatCredentialsFixture(key: nil), configuration: { ModelConfiguration() }, transport: transport)
        await model.start(); let a = try XCTUnwrap(model.sessions.first(where: \.isCurrent))
        model.draft = "A 新草稿"; model.requestNew(); try await wait { !model.busy }
        XCTAssertTrue(model.turns.isEmpty); XCTAssertEqual(model.sessions.count, 1)
        model.draft = "B 草稿"; model.selectSession(a); try await wait { !model.busy }
        XCTAssertEqual(model.draft, "A 新草稿"); XCTAssertEqual(model.turns.count, 1)
        model.requestDelete(a); XCTAssertTrue(model.confirmingDelete)
        model.confirmingDelete = false
        var sessions = try await store.chatSessions(); XCTAssertEqual(sessions.count, 2)
        model.requestDelete(a); model.deleteConversation(); try await wait { !model.busy }
        sessions = try await store.chatSessions(); XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(model.draft, "B 草稿")
        let calls = await transport.calls; XCTAssertEqual(calls, 0)
    }

    func testMaintenanceStopsAndMigrationPreservesChatRowsAndDraft() async throws {
        let model = ChatViewModel(store: store, credentials: ChatCredentialsFixture(key: "fixture"), configuration: { ModelConfiguration(baseURL: "https://example.com/v1", model: "fixture") }, transport: ChatTransportFixture(mode: .slowSuccess))
        await model.start(); model.draft = "迁移测试"; model.send(); try await wait { model.turns.last?.answer == "第一段" }
        model.draft = "尚未发送"; let ready = await model.prepareForMaintenance(); XCTAssertTrue(ready)
        let parent = directory.appendingPathComponent("../chat-migration-" + UUID().uuidString).standardizedFileURL
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true); defer { TestTemporaryDirectory.remove(parent) }
        let target = try DataDirectoryMigration().migrate(store: store, parent: parent, location: DataLocationStore(controlDirectory: directory))
        let migrated = try JotBloomStore(dataDirectoryURL: target); defer { migrated.close() }
        let page = try await migrated.chatPage(); XCTAssertEqual(page.turns.last?.status, .stopped); XCTAssertEqual(page.turns.last?.answer, "第一段")
        XCTAssertEqual(try migrated.loadDraftSynchronously(kind: .aiChat)?.content, "尚未发送")
        XCTAssertEqual(try migrated.migrationRecordCounts(), try store.migrationRecordCounts())
    }
}

private actor ChatDeniedCredentials: CredentialStoring {
    var interactiveCalls = 0
    func readWithoutInteraction(_ slot: ModelSlot) async throws -> String? { throw SettingsError.credentialDenied }
    func read(_ slot: ModelSlot) async throws -> String? { interactiveCalls += 1; return "fixture" }
    func authorize(_ slot: ModelSlot) async throws -> String? { interactiveCalls += 1; return "fixture" }
    func write(_ secret: String, slot: ModelSlot) {}
    func remove(_ slot: ModelSlot) {}
}
private actor ChatDelayedCredentials: CredentialStoring {
    var pending: CheckedContinuation<String?, Never>?
    func readWithoutInteraction(_ slot: ModelSlot) async throws -> String? { await withCheckedContinuation { pending = $0 } }
    func read(_ slot: ModelSlot) async -> String? { await withCheckedContinuation { pending = $0 } }
    func resolve() { pending?.resume(returning: "fixture"); pending = nil }
    func write(_ secret: String, slot: ModelSlot) {}
    func remove(_ slot: ModelSlot) {}
}

private actor ChatCredentialsFixture: CredentialStoring {
    var reads = 0
    var key: String?
    init(key: String?) { self.key = key }
    func read(_ slot: ModelSlot) -> String? { reads += 1; return key }
    func readWithoutInteraction(_ slot: ModelSlot) -> String? { reads += 1; return key }
    func write(_ secret: String, slot: ModelSlot) { key = secret }
    func remove(_ slot: ModelSlot) { key = nil }
}
private actor ChatTransportFixture: ChatStreamingTransport {
    enum Mode { case success, slowSuccess, failFirst, partialFailure, unauthorized }
    let mode: Mode
    var calls = 0
    init(mode: Mode) { self.mode = mode }
    func stream(_ request: URLRequest, onText: @escaping @Sendable (String) async throws -> Void) async throws -> ChatStatus {
        calls += 1
        if mode == .failFirst && calls == 1 { throw URLError(.networkConnectionLost) }
        if mode == .unauthorized { throw SettingsError.http(401) }
        try await onText("第一段")
        if mode == .partialFailure { throw URLError(.networkConnectionLost) }
        if mode == .slowSuccess { try await Task.sleep(nanoseconds: 150_000_000) }
        try await onText("第二段"); return .complete
    }
}
