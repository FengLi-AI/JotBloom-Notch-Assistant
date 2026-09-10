import XCTest
@testable import JotBloomCore

final class AuthorizedCredentialSessionTests: XCTestCase {
    func testEmptySessionDoesNotInventAuthorization() throws {
        var session = AuthorizedCredentialSession<String>()
        XCTAssertNil(try session.read(.main) { _ in XCTFail("No context to validate") })
    }

    func testAuthorizedReadCanBeReusedAndChecksOriginalContextEveryTime() throws {
        var session = AuthorizedCredentialSession<String>()
        session.remember("fixture", slot: .main, context: "original-keychain")
        var checks = 0
        for _ in 0..<3 {
            XCTAssertEqual(try session.read(.main) { context in
                XCTAssertEqual(context, "original-keychain"); checks += 1
            }, "fixture")
        }
        XCTAssertEqual(checks, 3)
    }

    func testAuthorizationDoesNotCrossSlots() throws {
        var session = AuthorizedCredentialSession<String>()
        session.remember("main-fixture", slot: .main, context: "main-keychain")
        XCTAssertNil(try session.read(.auxiliary) { _ in XCTFail() })
        session.remember("aux-fixture", slot: .auxiliary, context: "aux-keychain")
        XCTAssertEqual(try session.read(.main) { XCTAssertEqual($0, "main-keychain") }, "main-fixture")
        XCTAssertEqual(try session.read(.auxiliary) { XCTAssertEqual($0, "aux-keychain") }, "aux-fixture")
    }

    func testLockedOrUnavailableContextEvictsCredential() throws {
        for error in [SettingsError.credentialLocked, .credentialUnavailable, .credentialDenied] {
            var session = AuthorizedCredentialSession<String>()
            session.remember("fixture", slot: .main, context: "fixture-keychain")
            XCTAssertThrowsError(try session.read(.main) { _ in throw error }) {
                XCTAssertEqual($0 as? SettingsError, error)
            }
            XCTAssertNil(try session.read(.main) { _ in XCTFail("Unlocking must not revive evicted secrets") })
        }
    }

    func testRemoveOrFailedReplacementCannotReuseOldSecret() throws {
        var session = AuthorizedCredentialSession<String>()
        session.remember("old-fixture", slot: .main, context: "old")
        session.remember("aux-fixture", slot: .auxiliary, context: "aux")
        session.remove(.main)
        XCTAssertNil(try session.read(.main) { _ in XCTFail() })
        XCTAssertEqual(try session.read(.auxiliary) { _ in }, "aux-fixture")
        session.remember("new-fixture", slot: .main, context: "new")
        XCTAssertEqual(try session.read(.main) { XCTAssertEqual($0, "new") }, "new-fixture")
    }

    func testNewSessionDoesNotRetainPreviousAuthorization() throws {
        var first = AuthorizedCredentialSession<String>()
        first.remember("fixture", slot: .main, context: "fixture-keychain")
        var restarted = AuthorizedCredentialSession<String>()
        XCTAssertNil(try restarted.read(.main) { _ in XCTFail() })
    }
}
