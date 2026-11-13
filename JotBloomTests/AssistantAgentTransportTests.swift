import XCTest
@testable import JotBloomCore

final class AssistantAgentTransportTests: XCTestCase {
    func testFragmentedAndBatchedJSONWithLargeStderrDoesNotDeadlock() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let script = root.appendingPathComponent("server.py")
        try #"""
import json,sys
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 sys.stderr.write('diagnostic' * 100000);sys.stderr.flush()
 msg=json.dumps({'id':r['id'],'result':{'message':'成功'}}).encode()
 sys.stdout.buffer.write(msg[:7]);sys.stdout.buffer.flush()
 sys.stdout.buffer.write(msg[7:]+b'\n'+json.dumps({'method':'fixture/event','params':{}}).encode()+b'\n');sys.stdout.buffer.flush()
"""#.write(to: script, atomically: true, encoding: .utf8)
        let rpc = AgentRPCTransport()
        try await rpc.launch("/usr/bin/python3", arguments: [script.path])
        async let first = rpc.request("fixture/one", .object([:]), timeout: 5_000_000_000)
        async let second = rpc.request("fixture/two", .object([:]), timeout: 5_000_000_000)
        let results = try await [first, second]
        XCTAssertEqual(results.map { $0["message"].text }, ["成功", "成功"])
        await rpc.close()
    }
    func testRequestTimeoutDoesNotResendAndCloseResolvesOutstandingRequest() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let script = root.appendingPathComponent("server.py")
        try "import sys\nfor line in sys.stdin:\n pass\n".write(to: script, atomically: true, encoding: .utf8)
        let rpc = AgentRPCTransport(); try await rpc.launch("/usr/bin/python3", arguments: [script.path])
        do { _ = try await rpc.request("ignore", .object([:]), timeout: 100_000_000); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        let pending = Task { try await rpc.request("pending", .object([:])) }
        try await Task.sleep(nanoseconds: 30_000_000); await rpc.close()
        do { _ = try await pending.value; XCTFail() } catch {}
    }
    func testMalformedLineFailsConnectionInsteadOfDiscardingUnknownApproval() async throws {
        let root = try TestTemporaryDirectory.make(); defer { TestTemporaryDirectory.remove(root) }
        let script = root.appendingPathComponent("server.py")
        try "import sys\nfor line in sys.stdin:\n print('not-json',flush=True)\n".write(to: script, atomically: true, encoding: .utf8)
        let rpc = AgentRPCTransport(); try await rpc.launch("/usr/bin/python3", arguments: [script.path])
        do { _ = try await rpc.request("fixture", .object([:]), timeout: 5_000_000_000); XCTFail() } catch {}
        await rpc.close()
    }
}

extension AssistantExecutionTests {
    func testAgentAndSelfSlotsRunTogetherAndWaitingAgentYieldsToAnotherAgent() async throws {
        let fixture = FixtureAgentConnector(), coordinator = AssistantCoordinator(store: store, agentConnector: fixture)
        await coordinator.start(); await coordinator.agentService.configurePath("fixture")
        let first = try await prepared(allowCodex: true)
        try await Task.sleep(nanoseconds: 5_000_000)
        let second = try await prepared(allowCodex: true)
        let selfTask = try await prepared()
        let delegate = json(.delegateToCodex, ["instructions": .string("fixture task")]), written = write(), finished = finish()
        try await coordinator.reload()
        coordinator.executionModel = { context in
            if context.contains("\"allowCodex\":true") { return delegate }
            return context.contains("write_result_file；状态 done") ? finished : written
        }
        for _ in 0..<200 { if await fixture.snapshot().0 == 1 && coordinator.tasks.first(where: { $0.id == selfTask.id })?.status == .completed { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(coordinator.tasks.first { $0.id == first.id }?.status, .running)
        XCTAssertEqual(coordinator.tasks.first { $0.id == second.id }?.status, .queued)
        XCTAssertEqual(coordinator.tasks.first { $0.id == selfTask.id }?.status, .completed)
        await fixture.emit("item/fileChange/requestApproval", request: .string("q"))
        for _ in 0..<200 { if await fixture.snapshot().0 == 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(coordinator.tasks.first { $0.id == first.id }?.status, .waitingUser)
        XCTAssertEqual(coordinator.tasks.first { $0.id == second.id }?.status, .running)
        let pendingValue = try await store.executionQuestion(id: first.id), pending = try XCTUnwrap(pendingValue)
        try await coordinator.answerAgent(first.id, question: pending.id, decision: .decline)
        let before = await fixture.snapshot(); XCTAssertEqual(before.1, 0)
        XCTAssertEqual(coordinator.tasks.first { $0.id == first.id }?.status, .queued)
        await coordinator.pauseAndDrain()
        let after = await fixture.snapshot(); XCTAssertGreaterThanOrEqual(after.2, 2)
    }
    func testAgentMigrationPreservesVersionTenRuntimeAndCopiesOwnedThreads() async throws {
        let task = try await prepared(allowCodex: true)
        try await store.transitionAssistantTask(id: task.id, event: .executionStarted, text: "fixture")
        var state = AssistantExecutionState(); state.calls = 7
        try await store.saveExecutionState(id: task.id, state: state)
        var session = AgentSession(); session.threadID = "backup-thread"
        try await store.saveAgentSession(id: task.id, session: session)
        let counts = try store.migrationRecordCounts()
        XCTAssertEqual(Array(counts.suffix(3)), [1, 1, 1])
        try store.performSync { db in
            try db.execute("DROP TABLE assistant_agent_sessions; DROP TABLE assistant_owned_threads; ALTER TABLE assistant_reminders DROP COLUMN origin; PRAGMA user_version=10", operation: "fixture_v10")
            try DatabaseMigrator.bootstrap(db)
        }
        let restored = try await store.executionState(id: task.id)
        XCTAssertEqual(restored.calls, 7)
        let saved = try await store.assistantTask(id: task.id); XCTAssertEqual(saved?.scope, task.scope)
    }
}
