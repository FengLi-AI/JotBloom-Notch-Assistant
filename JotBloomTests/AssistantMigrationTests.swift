import XCTest
@testable import JotBloomCore

final class AssistantMigrationTests: XCTestCase {
    private func versionEight(_ db: SQLiteConnection) throws {
        try DatabaseMigrator.createVersionTwo(db); try DatabaseMigrator.migrateVersionTwoToThree(db)
        try DatabaseMigrator.migrateVersionThreeToFour(db); try DatabaseMigrator.migrateVersionFourToFive(db)
        try DatabaseMigrator.migrateVersionFiveToSix(db); try DatabaseMigrator.migrateVersionSixToSeven(db)
        try db.execute("CREATE TABLE file_shelf(id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL, sort_order INTEGER NOT NULL); PRAGMA user_version=8", operation: "v8_fixture")
    }
    func testRealV8MigrationPreservesEveryLegacyTableAndBacksUpV8() async throws {
        let directory = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(directory) }
        let url = directory.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let db = try SQLiteConnection(databaseURL: url)
        try versionEight(db)
        try db.execute("""
            INSERT INTO inspirations(id,title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source,sort_order) VALUES(42,'旧标题','旧正文','文章类','user',1,2,'manual',77);
            INSERT INTO chat_sessions(id,slot,token,updated_at_utc_ms,title,draft) VALUES(9,1,'old-session',3,'已有对话','');
            INSERT INTO chat_messages(id,session_id,role,content,created_at_utc_ms,turn_token,attempt_token,state) VALUES(40,9,'user','原问题',99,'turn','attempt','complete'),(41,9,'assistant','原完整回答',100,'turn','attempt','complete');
            INSERT INTO drafts(kind,content,updated_at_utc_ms) VALUES('ai_chat','旧聊天草稿',101),('inspiration','旧灵感草稿',102);
            INSERT INTO clipboard_items(id,content_type,text_content,content_byte_count,copied_at_utc_ms) VALUES(17,'text','仅旧库回归使用的剪贴板样例',36,98);
            INSERT INTO prompts(id,title,content,title_source,created_at_utc_ms,origin_kind,source_clipboard_id,submission_token,lifecycle_token) VALUES(18,'旧提示词','保留原文与收藏关系','user',99,'clipboard',17,'legacy-prompt','legacy-life');
            """, operation: "v8_seed")
        let source = directory.appendingPathComponent("legacy-file.txt")
        try Data("旧文件原文".utf8).write(to: source)
        let reference = try FileReference.create(url: source)
        let row = try db.prepare("INSERT INTO file_shelf(id,payload,sort_order) VALUES(?,?,33)", operation: "v8_file_reference")
        try row.bind(reference.id.uuidString, at: 1)
        try row.bind(String(decoding: JSONEncoder().encode(reference), as: UTF8.self), at: 2); try row.executeDone()
        db.close()
        let store = try JotBloomStore(dataDirectoryURL: directory); defer { store.close() }
        XCTAssertEqual(try store.schemaVersionSynchronously(), DatabaseMigrator.currentVersion)
        let page = try await store.chatPage(); XCTAssertEqual(page.turns.first?.answer, "原完整回答")
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .aiChat)?.content, "旧聊天草稿")
        XCTAssertEqual(try store.loadDraftSynchronously(kind: .inspiration)?.content, "旧灵感草稿")
        XCTAssertEqual(try store.inspirationSynchronously(id: 42).body, "旧正文")
        XCTAssertEqual(try store.promptSynchronously(id: 18)?.content, "保留原文与收藏关系")
        let shelf = try await store.loadFileShelf()
        XCTAssertEqual(shelf, [reference]); XCTAssertEqual(try shelf[0].resolved().url, reference.url)
        XCTAssertEqual(try String(contentsOf: source), "旧文件原文")
        let tasks = try await store.assistantTasks(); XCTAssertTrue(tasks.isEmpty)
        let backupURL = url.appendingPathExtension("bak-v8")
        let backup = try SQLiteConnection(databaseURL: backupURL, readOnly: true); defer { backup.close() }
        XCTAssertEqual(try backup.userVersion(), 8)
        XCTAssertFalse(try backup.objectExists(type: "table", name: "assistant_tasks"))
        try store.performSync { upgraded in
            for table in ["inspirations", "clipboard_items", "prompts", "chat_sessions", "chat_messages", "drafts", "file_shelf"] {
                func rows(_ db: SQLiteConnection) throws -> [String] {
                    // Compare every original column byte-for-byte through SQLite's canonical dump.
                    let columns = try db.prepare("PRAGMA table_info(\(table))", operation: "columns")
                    var names: [String] = []; while try columns.stepRow() { names.append(columns.text(at: 1)) }
                    let expression = names.map { "quote(\($0))" }.joined(separator: "||'|'||")
                    let values = try db.prepare("SELECT \(expression) FROM \(table) ORDER BY rowid", operation: "values")
                    var result: [String] = []; while try values.stepRow() { result.append(values.text(at: 0)) }; return result
                }
                XCTAssertEqual(try rows(upgraded), try rows(backup), table)
            }
        }
    }
    func testVersionNineUpgradeKeepsTaskStepsAndMakesVersionNineBackup() async throws {
        let directory = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(directory) }
        let url = directory.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let db = try SQLiteConnection(databaseURL: url)
        try versionEight(db); try DatabaseMigrator.migrateVersionEightToNine(db)
        try db.execute("""
            INSERT INTO assistant_tasks(id,title,raw_input,source_kind,status,created_at_ms,updated_at_ms) VALUES('old','旧交办','原始内容','notchText','interrupted',1,2);
            INSERT INTO assistant_task_steps(task_id,step_index,tool,args_json,decision,state,result_text,created_at_ms) VALUES('old',0,'list_result_files','{}','allow','done','已有结果',3);
            INSERT INTO assistant_task_events(task_id,kind,text,created_at_ms) VALUES('old','progress','原始进度',4);
            """, operation: "v9_fixture")
        db.close()
        let store = try JotBloomStore(dataDirectoryURL: directory); defer { store.close() }
        let task = try await store.assistantTask(id: "old"), steps = try await store.executionSteps(id: "old")
        XCTAssertEqual(task?.rawInput, "原始内容"); XCTAssertEqual(task?.status, .interrupted)
        XCTAssertEqual(steps.first?.result, "已有结果")
        let runtime = try await store.executionState(id: "old"); XCTAssertEqual(runtime.calls, 0)
        let backup = try SQLiteConnection(databaseURL: url.appendingPathExtension("bak-v9"), readOnly: true); defer { backup.close() }
        XCTAssertEqual(try backup.userVersion(), 9)
        XCTAssertFalse(try backup.objectExists(type: "table", name: "assistant_task_runtime"))
    }
    func testVersionTenMigrationConflictRollsBack() throws {
        let directory = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(directory) }
        let db = try SQLiteConnection(databaseURL: directory.appendingPathComponent("conflict.sqlite")); defer { db.close() }
        try versionEight(db); try DatabaseMigrator.migrateVersionEightToNine(db)
        try db.execute("CREATE TABLE assistant_task_runtime(existing TEXT)", operation: "conflict")
        XCTAssertThrowsError(try DatabaseMigrator.migrateVersionNineToTen(db))
        XCTAssertEqual(try db.userVersion(), 9)
        _ = try db.prepare("SELECT existing FROM assistant_task_runtime", operation: "preserved")
    }
    func testVersionElevenReminderMigrationPreservesLegacyDataAndBackup() async throws {
        let directory = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(directory) }
        let url = directory.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let db = try SQLiteConnection(databaseURL: url)
        try versionEight(db); try DatabaseMigrator.migrateVersionEightToNine(db)
        try DatabaseMigrator.migrateVersionNineToTen(db); try DatabaseMigrator.migrateVersionTenToEleven(db)
        try db.execute("""
            INSERT INTO assistant_tasks(id,title,raw_input,source_kind,status,created_at_ms,updated_at_ms) VALUES('old','旧提醒','原文','notchText','scheduled',1,2);
            INSERT INTO assistant_reminders(id,task_id,fire_at_ms,state) VALUES('reminder','old',987654321,'pending');
            """, operation: "v11_reminder_fixture")
        db.close()
        let store = try JotBloomStore(dataDirectoryURL: directory); defer { store.close() }
        let reminders = try await store.assistantReminders()
        XCTAssertEqual(reminders.count, 1); XCTAssertEqual(reminders.first?.origin, .auto)
        XCTAssertEqual(reminders.first?.fireAt, 987654321); XCTAssertEqual(reminders.first?.id, "reminder")
        XCTAssertEqual(try store.schemaVersionSynchronously(), 12)
        let backup = try SQLiteConnection(databaseURL: url.appendingPathExtension("bak-v11"), readOnly: true); defer { backup.close() }
        XCTAssertEqual(try backup.userVersion(), 11)
        XCTAssertThrowsError(try backup.prepare("SELECT origin FROM assistant_reminders", operation: "old_schema"))
        try store.performSync { upgraded in
            XCTAssertThrowsError(try upgraded.execute("UPDATE assistant_reminders SET origin='unknown'", operation: "invalid_origin"))
            try DatabaseMigrator.bootstrap(upgraded) // Reopening v12 does not replay ALTER TABLE.
        }
    }
    func testReminderOriginMigrationConflictRollsBackVersion() throws {
        let directory = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(directory) }
        let db = try SQLiteConnection(databaseURL: directory.appendingPathComponent("conflict.sqlite")); defer { db.close() }
        try versionEight(db); try DatabaseMigrator.migrateVersionEightToNine(db)
        try DatabaseMigrator.migrateVersionNineToTen(db); try DatabaseMigrator.migrateVersionTenToEleven(db)
        try db.execute("ALTER TABLE assistant_reminders ADD COLUMN origin TEXT", operation: "fixture_conflict")
        XCTAssertThrowsError(try DatabaseMigrator.migrateVersionElevenToTwelve(db))
        XCTAssertEqual(try db.userVersion(), 11)
    }
    func testMigrationFailureRollsBackVersionAndPartialTables() throws {
        let directory = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(directory) }
        let db = try SQLiteConnection(databaseURL: directory.appendingPathComponent("rollback.sqlite")); defer { db.close() }
        try versionEight(db)
        try db.execute("CREATE TABLE assistant_questions(fixture TEXT)", operation: "conflict")
        XCTAssertThrowsError(try DatabaseMigrator.migrateVersionEightToNine(db))
        XCTAssertEqual(try db.userVersion(), 8)
        XCTAssertFalse(try db.objectExists(type: "table", name: "assistant_tasks"))
        XCTAssertFalse(try db.objectExists(type: "table", name: "assistant_task_events"))
        XCTAssertTrue(try db.objectExists(type: "table", name: "assistant_questions"))
    }
}
