import XCTest
@testable import JotBloomCore

final class CoordinatedCredentialStoreTests: XCTestCase {
    func testConcreteAndProtocolSilentCallsUseSameMemoryImplementation() async throws {
        let store = MemoryCredentialStore()
        await store.write("fixture", slot: .main)
        let concrete = try await store.readWithoutInteraction(.main)
        let existential: any CredentialStoring = store
        let throughProtocol = try await existential.readWithoutInteraction(.main)
        XCTAssertEqual(concrete, "fixture"); XCTAssertEqual(throughProtocol, concrete)
    }
    func testSilentAccessSkipsAuthorizationAndMissingKeyDoesNotPrompt() async throws {
        let base = CredentialGateFixture(), store = CoordinatedCredentialStore(base: base)
        await base.setAuthorized(true)
        let value = try await store.read(.main); XCTAssertEqual(value, "fixture-main")
        try await store.remove(.main)
        let missing = try await store.read(.main); XCTAssertNil(missing)
        let calls = await base.interactiveCount; XCTAssertEqual(calls, 0)
    }
    func testConcurrentReadersShareOneAuthorizationThenReuse() async throws {
        let base = CredentialGateFixture(), store = CoordinatedCredentialStore(base: base)
        async let first = store.authorize(.main)
        async let second = store.authorize(.main)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, "fixture-main"); XCTAssertEqual(b, a)
        _ = try await store.read(.main)
        let calls = await base.interactiveCount; XCTAssertEqual(calls, 1)
    }
    func testDenialIsSharedAndNextExplicitAttemptCanRetry() async throws {
        let base = CredentialGateFixture(), store = CoordinatedCredentialStore(base: base)
        await base.fail(.credentialDenied)
        async let first: String? = store.authorize(.main)
        async let second: String? = store.authorize(.main)
        do { _ = try await first; XCTFail() } catch { XCTAssertEqual(error as? SettingsError, .credentialDenied) }
        do { _ = try await second; XCTFail() } catch { XCTAssertEqual(error as? SettingsError, .credentialDenied) }
        var calls = await base.interactiveCount; XCTAssertEqual(calls, 1)
        await base.fail(nil)
        _ = try await store.authorize(.main)
        calls = await base.interactiveCount; XCTAssertEqual(calls, 2)
    }
    func testCancelledCallerDoesNotUseLateResultOrCancelOtherReader() async throws {
        let base = CredentialGateFixture(), store = CoordinatedCredentialStore(base: base)
        let first = Task { try await store.authorize(.main) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let second = Task { try await store.authorize(.main) }
        first.cancel()
        do { _ = try await first.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let value = try await second.value; XCTAssertEqual(value, "fixture-main")
        let calls = await base.interactiveCount; XCTAssertEqual(calls, 1)
    }
    func testSlotIsolationAndBackgroundNeverPrompts() async throws {
        let base = CredentialGateFixture(), store = CoordinatedCredentialStore(base: base)
        do { _ = try await store.readWithoutInteraction(.main); XCTFail() } catch {}
        var calls = await base.interactiveCount; XCTAssertEqual(calls, 0)
        let main = try await store.authorize(.main), aux = try await store.authorize(.auxiliary)
        XCTAssertEqual(main, "fixture-main"); XCTAssertEqual(aux, "fixture-aux")
        calls = await base.interactiveCount; XCTAssertEqual(calls, 2)
    }
    func testRemoveDuringAuthorizationRejectsStaleResult() async throws {
        let base = CredentialGateFixture(), store = CoordinatedCredentialStore(base: base)
        let pending = Task { try await store.authorize(.main) }
        try await Task.sleep(nanoseconds: 10_000_000)
        try await store.remove(.main)
        do { _ = try await pending.value; XCTFail() } catch {}
        let missing = try await store.read(.main); XCTAssertNil(missing)
    }
    func testUnderlyingRevocationIsNotHiddenByCoordinator() async throws {
        let base = CredentialGateFixture(), store = CoordinatedCredentialStore(base: base)
        _ = try await store.authorize(.main)
        await base.setAuthorized(false); await base.fail(.credentialDenied)
        do { _ = try await store.readWithoutInteraction(.main); XCTFail() } catch {}
        do { _ = try await store.read(.main); XCTFail() } catch { XCTAssertEqual(error as? SettingsError, .credentialDenied) }
        let calls = await base.interactiveCount; XCTAssertEqual(calls, 1)
    }
    func testSystemDialogCancellationDoesNotAutomaticallyRetry() async throws {
        let base = CredentialGateFixture(), store = CoordinatedCredentialStore(base: base)
        await base.fail(.credentialCancelled)
        do { _ = try await store.authorize(.main); XCTFail() }
        catch { XCTAssertEqual(error as? SettingsError, .credentialCancelled) }
        let calls = await base.interactiveCount; XCTAssertEqual(calls, 1)
    }
    func testRepeatedDailyReadsNeverRequestAuthorization() async throws {
        let base = CredentialGateFixture(), store = CoordinatedCredentialStore(base: base)
        for _ in 0..<3 {
            do { _ = try await store.read(.main); XCTFail() }
            catch { XCTAssertEqual(error as? SettingsError, .credentialDenied) }
        }
        let calls = await base.interactiveCount; XCTAssertEqual(calls, 0)
    }
}

private actor CredentialGateFixture: CredentialStoring {
    private var keys: [ModelSlot: String] = [.main: "fixture-main", .auxiliary: "fixture-aux"]
    private var authorized: Set<ModelSlot> = []
    private var failure: SettingsError?
    var interactiveCount = 0
    func setAuthorized(_ value: Bool) { authorized = value ? [.main, .auxiliary] : [] }
    func fail(_ error: SettingsError?) { failure = error }
    func readWithoutInteraction(_ slot: ModelSlot) async throws -> String? {
        guard keys[slot] != nil else { return nil }
        guard authorized.contains(slot) else { throw SettingsError.credentialDenied }
        return keys[slot]
    }
    func read(_ slot: ModelSlot) async throws -> String? { try await readWithoutInteraction(slot) }
    func authorize(_ slot: ModelSlot) async throws -> String? {
        interactiveCount += 1
        let captured = keys[slot]
        // A real authorization dialog can finish after the initiating task cancels.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { continuation.resume() }
        }
        if let failure { throw failure }
        authorized.insert(slot); return captured
    }
    func write(_ secret: String, slot: ModelSlot) { keys[slot] = secret; authorized.remove(slot) }
    func remove(_ slot: ModelSlot) { keys.removeValue(forKey: slot); authorized.remove(slot) }
}
