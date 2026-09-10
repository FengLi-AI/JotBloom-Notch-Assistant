import XCTest
@testable import JotBloomCore

final class PanelPreferencesTests: XCTestCase {
    func testNormalizesMissingAndDuplicateSlots() {
        let value = PanelPreferences(order: [.clipboard, .clipboard])
        XCTAssertEqual(value.order.first, .clipboard)
        XCTAssertEqual(value.order.count, 6)
        XCTAssertEqual(Set(value.order), Set(PanelSlot.allCases))
    }

    func testChatAndOtherReleasedSlotsCanBeDefault() {
        var value = PanelPreferences(defaultSlot: .chat)
        XCTAssertEqual(value.defaultSlot, .chat)
        value.defaultSlot = .prompts
        XCTAssertEqual(value.defaultSlot, .prompts)
        value.defaultSlot = .globalSearch
        XCTAssertEqual(value.defaultSlot, .globalSearch)
    }

    func testMovingPreservesAllSlotsAndChecksBoundaries() {
        var value = PanelPreferences()
        value.move(.inspiration, by: -1)
        XCTAssertEqual(value.order, PanelSlot.allCases)
        value.move(.globalSearch, by: 1)
        XCTAssertEqual(value.order, PanelSlot.allCases)
        value.move(.clipboard, by: -1)
        XCTAssertEqual(value.order.first, .clipboard)
        XCTAssertEqual(Set(value.order), Set(PanelSlot.allCases))
    }

    func testPreferencesRoundTripWithoutTouchingStandardDefaults() throws {
        let suite = "JotBloomTests.PanelPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.load(), PanelPreferences())
        var value = PanelPreferences(defaultSlot: .inspirationLibrary, reduceMotion: true)
        value.move(.globalSearch, by: -1)
        store.save(value)
        XCTAssertEqual(PanelPreferencesStore(defaults: defaults).load(), value)
    }

    func testUnknownPersistedValuesRecoverSafely() throws {
        let suite = "JotBloomTests.PanelPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["order": ["future", "clipboard", "clipboard"], "default": "future"],
                     forKey: "jotbloom.panel.preferences.v1")
        let value = PanelPreferencesStore(defaults: defaults).load()
        XCTAssertEqual(value.order.first, .clipboard)
        XCTAssertEqual(value.order.count, 6)
        XCTAssertEqual(value.defaultSlot, .inspiration)
    }
}
