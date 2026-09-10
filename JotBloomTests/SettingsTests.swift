import Foundation
import XCTest
@testable import JotBloomCore

final class SettingsTests: XCTestCase {
    func testDefaultsAndMalformedFieldsDoNotResetPanelPreferences() {
        let suite = "JotBloom.SettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("untouched", forKey: "jotbloom.panel.preferences.v1")
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), AppSettings())
        defaults.set(["version": 99, "monitoringEnabled": false], forKey: "jotbloom.settings.v1")
        XCTAssertEqual(store.load(), AppSettings())
        defaults.set(["maximumCount": -1, "maximumDays": "wrong", "maximumBytes": -2, "shortcut": Data([0])], forKey: "jotbloom.settings.v1")
        XCTAssertEqual(store.load(), AppSettings())
        var changed = AppSettings(); changed.monitoringEnabled = false; changed.main.model = "test-model"
        store.save(changed)
        XCTAssertEqual(store.load(), changed)
        XCTAssertEqual(defaults.string(forKey: "jotbloom.panel.preferences.v1"), "untouched")
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("api-key"))
    }
    func testAllRetentionOptionsRoundTripAndUnlimited() {
        let suite = "JotBloom.SettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        for count in AppSettings.countOptions { for days in AppSettings.dayOptions { for bytes in AppSettings.byteOptions {
            var value = AppSettings(); value.maximumCount = count; value.maximumDays = days; value.maximumBytes = bytes
            store.save(value); XCTAssertEqual(store.load(), value)
            XCTAssertEqual(value.retentionPolicy.maximumCount, count == 0 ? nil : count)
            XCTAssertEqual(value.retentionPolicy.maximumAgeMilliseconds, days == 0 ? nil : Int64(days) * 86_400_000)
            XCTAssertEqual(value.retentionPolicy.maximumBytes, bytes == 0 ? nil : bytes)
        } } }
    }
    func testAuxiliaryResolutionNeverMixesFallbackCredentials() {
        var value = AppSettings()
        value.main = .init(baseURL: "https://main.test/v1", model: "main")
        value.auxiliary = .init(baseURL: "https://aux.test/v2", model: " ")
        value.auxiliaryUsesMain = false
        XCTAssertEqual(value.resolvedConfiguration(for: .auxiliary).configuration, value.main)
        XCTAssertEqual(value.resolvedConfiguration(for: .auxiliary).credentialSlot, .main)
        value.auxiliary.model = "aux"
        XCTAssertEqual(value.resolvedConfiguration(for: .auxiliary).configuration, value.auxiliary)
        XCTAssertEqual(value.resolvedConfiguration(for: .auxiliary).credentialSlot, .auxiliary)
        value.auxiliaryUsesMain = true
        XCTAssertEqual(value.resolvedConfiguration(for: .auxiliary).configuration, .init(baseURL: value.main.baseURL, model: "aux"))
        XCTAssertEqual(value.resolvedConfiguration(for: .auxiliary).credentialSlot, .main)
    }
    func testURLNormalizationPreservesPrefixes() throws {
        XCTAssertEqual(try ModelEndpoint.normalize(" https://example.test/v1/chat/completions/// "), "https://example.test/v1")
        XCTAssertEqual(try ModelEndpoint.normalize("https://example.test/custom"), "https://example.test/custom")
        for host in ["localhost", "127.0.0.1", "[::1]"] { XCTAssertNoThrow(try ModelEndpoint.normalize("http://\(host):8080/v1")) }
    }
    func testInvalidEndpointsAreRejected() {
        for url in ["", "not-a-url", "file:///tmp", "ftp://x.test", "http://example.test", "http://192.168.1.2", "http://localhost.evil.test", "https://name:secret@host.test", "https://host.test?key=secret", "https://host.test#fragment", "https://host .test", "https:///v1"] {
            XCTAssertThrowsError(try ModelEndpoint.normalize(url), url)
        }
    }
    func testShortcutReservedCombinationsAndMask() {
        XCTAssertTrue(Shortcut.standard.isValid)
        XCTAssertTrue(Shortcut(keyCode: 40, modifiers: 2048 | 4096, label: "⌃⌥K").isValid)
        for shortcut in [Shortcut(keyCode: 0, modifiers: 0, label: "A"), .init(keyCode: 49, modifiers: 512, label: "⇧Space"), .init(keyCode: 12, modifiers: 256, label: "⌘Q"), .init(keyCode: 55, modifiers: 256, label: "⌘"), .init(keyCode: 49, modifiers: 1, label: "bad")] { XCTAssertFalse(shortcut.isValid) }
        XCTAssertEqual(ModelEndpoint.maskedKey("123"), "••••")
        XCTAssertEqual(ModelEndpoint.maskedKey("fake-secret-1234"), "••••1234")
    }
    func testMemoryCredentialsKeepSlotsSeparate() async throws {
        let credentials = MemoryCredentialStore()
        await credentials.write("fixture-main", slot: .main); await credentials.write("fixture-aux", slot: .auxiliary)
        await credentials.remove(.main)
        let main = await credentials.read(.main), auxiliary = await credentials.read(.auxiliary)
        XCTAssertNil(main); XCTAssertEqual(auxiliary, "fixture-aux")
    }
    func testCapturePermissionRejectsOldGenerationAfterReenable() throws {
        let permission = CapturePermission()
        let token = try XCTUnwrap(permission.token)
        permission.setAllowed(false); permission.setAllowed(true)
        var called = false
        let result: Bool? = permission.commit(token: token) { called = true; return true }
        XCTAssertNil(result); XCTAssertFalse(called)
        XCTAssertEqual(permission.commit(token: try XCTUnwrap(permission.token)) { true }, true)
    }
}
