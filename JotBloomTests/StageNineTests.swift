import XCTest
@testable import JotBloomCore

@MainActor
final class StageNineTests: XCTestCase {
    private var directory: URL!
    private var store: JotBloomStore!
    override func setUp() async throws { directory = try TestTemporaryDirectory.make(); store = try JotBloomStore(dataDirectoryURL: directory) }
    override func tearDown() async throws { store.close(); TestTemporaryDirectory.remove(directory) }
    private func saved(_ text: String = "写一篇关于Agent和AGI的差别文章") throws -> Inspiration {
        try store.saveManualInspirationSynchronously(XCTUnwrap(InspirationTextParser.parse(text)), timestampUTCms: 100)
    }
    private func completed(_ text: String = "问题", answer: String = "回答") async throws -> ChatTurn {
        var row = try await store.submitChat(text, token: UUID().uuidString, source: .aiChat)
        row.answer = answer; row.status = .complete; try await store.updateChat(row); return row
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("fixture timeout"); throw ChatError.busy
    }
    func testEnrichmentPreservesExactOriginalTimeOrderAndDedupe() async throws {
        let text = String(repeating: "完整首行", count: 15) + "\n\n第二行  "
        let original = try saved(text), snapshot = try await store.inspirationAISnapshot(original.id)
        XCTAssertEqual(snapshot.content, text)
        XCTAssertTrue(try store.applyInspirationAISynchronously(.init(title: "Agent与AGI差异", category: .article), expected: snapshot))
        let result = try store.inspirationSynchronously(id: original.id)
        XCTAssertEqual(result.title, "Agent与AGI差异"); XCTAssertEqual(result.category, .article)
        XCTAssertEqual(result.body, text); XCTAssertEqual(result.createdAtUTCms, 100); XCTAssertEqual(result.updatedAtUTCms, 100)
        XCTAssertEqual(result.sortOrder, original.sortOrder)
        XCTAssertThrowsError(try saved(text))
    }
    func testManualTitleAndCategoryAreIndependentlyProtected() async throws {
        let original = try saved(), snapshot = try await store.inspirationAISnapshot(original.id)
        _ = try store.updateInspirationTextSynchronously(id: original.id, title: "人工标题", body: original.body, updatedAtUTCms: 200)
        XCTAssertTrue(try store.applyInspirationAISynchronously(.init(title: "自动标题", category: .article), expected: snapshot))
        var result = try store.inspirationSynchronously(id: original.id)
        XCTAssertEqual(result.title, "人工标题"); XCTAssertEqual(result.category, .article)
        let second = try saved("另一条灵感"), secondSnapshot = try await store.inspirationAISnapshot(second.id)
        _ = try store.updateInspirationCategorySynchronously(id: second.id, category: .idea, updatedAtUTCms: 200)
        XCTAssertTrue(try store.applyInspirationAISynchronously(.init(title: "另一条短标题", category: .work), expected: secondSnapshot))
        result = try store.inspirationSynchronously(id: second.id)
        XCTAssertEqual(result.title, "另一条短标题"); XCTAssertEqual(result.category, .idea); XCTAssertEqual(result.categorySource, .user)
    }
    func testContentABAAndDeleteRestoreInvalidateLateAI() async throws {
        let original = try saved(), snapshot = try await store.inspirationAISnapshot(original.id)
        _ = try store.updateInspirationTextSynchronously(id: original.id, title: original.title, body: "临时修改", updatedAtUTCms: 200)
        _ = try store.updateInspirationTextSynchronously(id: original.id, title: original.title, body: original.body, updatedAtUTCms: 300)
        XCTAssertFalse(try store.applyInspirationAISynchronously(.init(title: "过期标题", category: .article), expected: snapshot))
        let current = try await store.inspirationAISnapshot(original.id)
        let removed = try store.deleteInspirationSynchronously(id: original.id)
        XCTAssertFalse(try store.applyInspirationAISynchronously(.init(title: "过期标题", category: .article), expected: current))
        try store.restoreInspirationSynchronously(removed)
        XCTAssertFalse(try store.applyInspirationAISynchronously(.init(title: "过期标题", category: .article), expected: current))
    }
    func testInvalidFieldsAreIsolatedAndInvalidDirectWriteRejected() async throws {
        let category = try InspirationAIResult.parse(#"{"title":"a\nb","category":"文章类"}"#)
        XCTAssertNil(category.title); XCTAssertEqual(category.category, .article)
        let title = try InspirationAIResult.parse(#"{"title":"文章选题","category":"未知分类"}"#)
        XCTAssertEqual(title.title, "文章选题"); XCTAssertNil(title.category)
        XCTAssertThrowsError(try InspirationAIResult.parse("不是JSON"))
        XCTAssertThrowsError(try InspirationAIResult.parse(#"{"title":"","category":"invalid"}"#))
        let snapshot = try await store.inspirationAISnapshot(saved().id)
        XCTAssertThrowsError(try store.applyInspirationAISynchronously(.init(title: "\n", category: .article), expected: snapshot))
    }
    func testEmptySessionsNeverAccumulateAndDraftSurvivesRestart() async throws {
        let old = try await completed()
        for _ in 0..<12 {
            try await store.newChat(); try await store.newChat()
            let history = try await store.chatSessions(); XCTAssertEqual(history.count, 1)
            try await store.selectChat(old.session)
        }
        do {
            let db = try SQLiteConnection(databaseURL: directory.appendingPathComponent(DataDirectoryResolver.databaseFileName)); defer { db.close() }
            let count = try db.prepare("SELECT count(*) FROM chat_sessions", operation: "count_fixture")
            XCTAssertTrue(try count.stepRow()); XCTAssertEqual(count.int64(at: 0), 1)
        }
        try await store.newChat(); let draftSession = try await store.currentChatIdentity()
        try store.persistChatDraftSynchronously("\n \t", prompt: "还不应冻结")
        var history = try await store.chatSessions(); XCTAssertEqual(history.count, 1)
        try store.persistChatDraftSynchronously("未发送的想法", prompt: "写下时的偏好")
        try await store.newChat(); store.close(); store = try JotBloomStore(dataDirectoryURL: directory)
        history = try await store.chatSessions(); XCTAssertEqual(history.count, 2)
        try await store.selectChat(draftSession)
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "未发送的想法")
        let prompt = try await store.chatSystemPrompt(default: "后来改的偏好"); XCTAssertEqual(prompt, "写下时的偏好")
    }
    func testPromptSnapshotStartsOnContentNotBlankAndStaysWithSession() async throws {
        _ = try await store.currentChatIdentity()
        var prompt = try await store.chatSystemPrompt(default: "新偏好"); XCTAssertEqual(prompt, "新偏好")
        try store.persistChatDraftSynchronously("", prompt: "旧偏好")
        prompt = try await store.chatSystemPrompt(default: "新偏好"); XCTAssertEqual(prompt, "新偏好")
        try store.persistChatDraftSynchronously("草稿", prompt: "首份偏好")
        let first = try await store.currentChatIdentity()
        try store.persistChatDraftSynchronously("草稿修订", prompt: "第二份偏好")
        prompt = try await store.chatSystemPrompt(default: "新偏好"); XCTAssertEqual(prompt, "首份偏好")
        try await store.newChat()
        prompt = try await store.chatSystemPrompt(default: "新偏好"); XCTAssertEqual(prompt, "新偏好")
        try await store.selectChat(first)
        prompt = try await store.chatSystemPrompt(default: "新偏好"); XCTAssertEqual(prompt, "首份偏好")
        let messages = try ChatContext.messages(history: [], input: "问题", systemPrompt: prompt)
        XCTAssertTrue(messages[0]["content"]!.contains(ChatContext.productRules))
        XCTAssertTrue(messages[0]["content"]!.contains("首份偏好"))
    }
    func testSummaryOnlyCurrentCompleteTurnsAndExplicitRecentBudget() async throws {
        _ = try await completed("别的会话"); try await store.newChat()
        _ = try await completed("旧轮次", answer: String(repeating: "字", count: 7200))
        for i in 1...3 { _ = try await completed("最近\(i)") }
        _ = try await store.submitChat("未完成问题", token: "partial", source: .aiChat)
        do { _ = try await store.summaryContext(recentOnly: false); XCTFail() } catch { XCTAssertEqual(error as? ChatError, .tooLong) }
        let recent = try await store.summaryContext(recentOnly: true)
        XCTAssertEqual(recent.map(\.user), ["最近1", "最近2", "最近3"])
    }
    func testSummaryPreviewSaveDedupAndLeaveProtection() async throws {
        _ = try await completed("讨论个人网站")
        let transport = NineChatTransport(text: #"{"title":"个人网站方向","body":"先验证作品导航的需求。"}"#)
        let credentials = MemoryCredentialStore(); await credentials.write("fixture", slot: .main)
        let model = ChatViewModel(store: store, credentials: credentials, configuration: { .init(baseURL: "https://example.test/v1", model: "fixture") }, transport: transport)
        await model.start(); model.draft = "不发送的草稿"; model.showingHistory = true
        model.summarize(); try await wait { !model.busy }
        XCTAssertTrue(model.summaryPreview); XCTAssertFalse(model.showingHistory); XCTAssertFalse(model.canLeaveChat())
        XCTAssertTrue(try store.listRecentInspirationsSynchronously().isEmpty)
        model.summaryBody = "用户修订后的总结"; model.saveSummary(); try await wait { !model.busy }
        XCTAssertFalse(model.summaryPreview); XCTAssertTrue(model.canLeaveChat())
        let row = try XCTUnwrap(store.listRecentInspirationsSynchronously().first)
        XCTAssertEqual(row.body, "用户修订后的总结"); XCTAssertEqual(row.source, .aiChat)
        XCTAssertEqual(model.turns.count, 1); XCTAssertEqual(model.draft, "不发送的草稿")
        model.summarize(); try await wait { !model.busy }
        model.summaryBody = row.body; model.saveSummary(); try await wait { !model.busy }
        XCTAssertTrue(model.summaryPreview); XCTAssertEqual(try store.listRecentInspirationsSynchronously().count, 1)
        model.discardSummary(); XCTAssertFalse(model.summaryPreview)
        let payload = await transport.lastBody
        XCTAssertFalse(payload.contains("不发送的草稿")); XCTAssertTrue(payload.contains("讨论个人网站"))
    }
    func testFailedSummaryKeepsConversationAndDoesNotSave() async throws {
        let before = try await completed()
        let credentials = MemoryCredentialStore(); await credentials.write("fixture", slot: .main)
        let model = ChatViewModel(store: store, credentials: credentials, configuration: { .init(baseURL: "https://example.test/v1", model: "fixture") }, transport: NineChatTransport(text: "not json"))
        await model.start(); model.summarize(); try await wait { !model.busy }
        XCTAssertFalse(model.summaryPreview); XCTAssertEqual(model.turns, [before])
        XCTAssertTrue(try store.listRecentInspirationsSynchronously().isEmpty); XCTAssertNotNil(model.feedback)
    }
    func testSettingsRoundTripAndDefaultOff() {
        let suite = "JotBloom.StageNineTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        // Dedicated isolated preference suite; never read standard application preferences.
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(settings.load().inspirationAIEnabled)
        var value = settings.load(); value.inspirationAIEnabled = true; value.chatSystemPrompt = "先帮我澄清需求"
        settings.save(value); XCTAssertEqual(settings.load(), value)
    }
    func testEnrichmentRequestCapCompatibilityAndNoRetryFor401() async throws {
        let transport = NineJSONTransport(status: 200)
        let result = try await InspirationAIService(transport: transport).generate(content: String(repeating: "字", count: 3000), configuration: .init(baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash"), key: "fixture")
        XCTAssertEqual(result.category, .article)
        let captured = await transport.lastRequest
        let request = try XCTUnwrap(captured)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages[1]["content"]?.count, 2000); XCTAssertEqual(json["max_tokens"] as? Int, 256)
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        let denied = NineJSONTransport(status: 401)
        do { _ = try await InspirationAIService(transport: denied).generate(content: "文", configuration: .init(baseURL: "https://example.test", model: "fixture"), key: "fixture"); XCTFail() } catch {}
        let calls = await denied.calls; XCTAssertEqual(calls, 1)
    }
    func testV6MigrationBackupPreservesHistoryDraftsAndOrder() async throws {
        let oldDir = directory.appendingPathComponent("v6")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let url = oldDir.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        do {
            let db = try SQLiteConnection(databaseURL: url); defer { db.close() }
            try DatabaseMigrator.createVersionTwo(db); try DatabaseMigrator.migrateVersionTwoToThree(db)
            try DatabaseMigrator.migrateVersionThreeToFour(db); try DatabaseMigrator.migrateVersionFourToFive(db)
            try DatabaseMigrator.migrateVersionFiveToSix(db)
            try db.execute("INSERT INTO inspirations(id,title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source,sort_order) VALUES(42,'旧首行','旧正文','文章类','user',1,2,'manual',77); INSERT INTO chat_sessions(slot,token,updated_at_utc_ms,title) VALUES(1,'old-session',3,'已有草稿'); INSERT INTO drafts(kind,content,updated_at_utc_ms) VALUES('ai_chat','旧草稿',3);", operation: "seed_v6")
        }
        let upgraded = try JotBloomStore(dataDirectoryURL: oldDir); defer { upgraded.close() }
        XCTAssertEqual(try upgraded.schemaVersionSynchronously(), 7)
        let record = try upgraded.inspirationSynchronously(id: 42)
        XCTAssertEqual(record.body, "旧首行\n旧正文"); XCTAssertEqual(record.categorySource, .user); XCTAssertEqual(record.sortOrder, 77)
        XCTAssertEqual(record.updatedAtUTCms, 2)
        let snapshot = try await upgraded.chatSystemPrompt(default: "新偏好"); XCTAssertEqual(snapshot, ChatContext.legacySystem)
        let history = try await upgraded.chatSessions(); XCTAssertEqual(history.first?.id, "old-session")
        XCTAssertEqual(try upgraded.loadDraftSynchronously(kind: .aiChat)?.content, "旧草稿")
        let backup = try SQLiteConnection(databaseURL: url.appendingPathExtension("bak-v6"), readOnly: true); defer { backup.close() }
        XCTAssertEqual(try backup.userVersion(), 6)
    }
    func testSharedHelperQueueIsBoundedAndCancellationReleasesSlots() async throws {
        let queue = PromptTitleCoordinator(store: store, credentials: MemoryCredentialStore(), settings: { AppSettings() })
        var started = 0, peak = 0, running = 0
        queue.additionalJob = { _ in
            started += 1; running += 1; peak = max(peak, running)
            defer { running -= 1 }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        for id in 1...34 { XCTAssertTrue(queue.enqueueInspiration(Int64(id))) }
        XCTAssertFalse(queue.enqueueInspiration(35))
        try await wait { started == 2 }; XCTAssertEqual(peak, 2)
        await queue.drain(); XCTAssertEqual(queue.activeCount, 0); XCTAssertEqual(started, 2)
    }
}

private actor NineChatTransport: ChatStreamingTransport {
    let text: String
    var lastBody = ""
    init(text: String) { self.text = text }
    func stream(_ request: URLRequest, onText: @escaping @Sendable (String) async throws -> Void) async throws -> ChatStatus {
        lastBody = String(data: request.httpBody!, encoding: .utf8)!
        try await onText(text); return .complete
    }
}
private actor NineJSONTransport: ConnectionTransport {
    let status: Int; var calls = 0; var lastRequest: URLRequest?
    init(status: Int) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1; lastRequest = request
        let response: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": #"{"title":"Agent与AGI差异","category":"文章类"}"#]]]]
        return (try JSONSerialization.data(withJSONObject: response), status)
    }
}
