import XCTest
@testable import JotBloomCore

final class PanelPreferencesTests: XCTestCase {
    func testDefaultOrderKeepsSearchOutsideBusinessTabs() {
        XCTAssertEqual(PanelPreferences().order,
                       [.inspiration, .inspirationLibrary, .clipboard, .prompts, .fileShelf, .chat])
        var value = PanelPreferences()
        value.move(.globalSearch, by: -1)
        XCTAssertEqual(value.order, PanelSlot.navigationSlots)
    }

    func testOldDefaultMigratesButCustomAndNewlySavedOrdersSurvive() throws {
        let suite = "JotBloomTests.NavigationMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelPreferencesStore(defaults: defaults)
        let oldDefault: [PanelSlot] = [.inspiration, .clipboard, .prompts, .inspirationLibrary, .chat, .fileShelf]
        for lastSlot in [PanelSlot.globalSearch, .fileShelf] {
            defaults.set(["order": (Array(oldDefault.dropLast()) + [lastSlot]).map(\.rawValue),
                          "default": "clipboard", "appearance": "light", "reduceMotion": true],
                         forKey: "jotbloom.panel.preferences.v1")
            let migrated = store.load()
            XCTAssertEqual(migrated.order, PanelSlot.navigationSlots)
            XCTAssertEqual(migrated.defaultSlot, .clipboard)
            XCTAssertEqual(migrated.appearance, .light)
            XCTAssertTrue(migrated.reduceMotion)
        }
        let custom = Array(oldDefault.reversed())
        defaults.set(["order": custom.map(\.rawValue)], forKey: "jotbloom.panel.preferences.v1")
        XCTAssertEqual(store.load().order, custom)
        // A user deliberately recreating the former arrangement must not be migrated again.
        store.save(PanelPreferences(order: oldDefault))
        XCTAssertEqual(store.load().order, oldDefault)
    }

    func testNormalizesMissingAndDuplicateSlots() {
        let value = PanelPreferences(order: [.clipboard, .clipboard])
        XCTAssertEqual(value.order.first, .clipboard)
        XCTAssertEqual(value.order.count, 6)
        XCTAssertEqual(Set(value.order), Set(PanelSlot.navigationSlots))
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
        XCTAssertEqual(value.order, PanelSlot.navigationSlots)
        value.move(.chat, by: 1)
        XCTAssertEqual(value.order, PanelSlot.navigationSlots)
        value.move(.inspirationLibrary, by: -1)
        XCTAssertEqual(value.order.first, .inspirationLibrary)
        XCTAssertEqual(Set(value.order), Set(PanelSlot.navigationSlots))
    }

    func testPreferencesRoundTripWithoutTouchingStandardDefaults() throws {
        let suite = "JotBloomTests.PanelPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.load(), PanelPreferences())
        var value = PanelPreferences(defaultSlot: .inspirationLibrary, reduceMotion: true, appearance: .light)
        value.move(.fileShelf, by: -1)
        store.save(value)
        XCTAssertEqual(PanelPreferencesStore(defaults: defaults).load(), value)
    }

    func testUnknownPersistedValuesRecoverSafely() throws {
        let suite = "JotBloomTests.PanelPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["order": ["future", "clipboard", "clipboard"], "default": "future", "appearance": "sepia"],
                     forKey: "jotbloom.panel.preferences.v1")
        let value = PanelPreferencesStore(defaults: defaults).load()
        XCTAssertEqual(value.order.first, .clipboard)
        XCTAssertEqual(value.order.count, 6)
        XCTAssertEqual(value.defaultSlot, .inspiration)
        XCTAssertEqual(value.appearance, .dark)
    }
    func testLegacyPreferencesRetainRoutesAndDefaultToDark() throws {
        let suite = "JotBloomTests.Appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["order": ["chat", "clipboard"], "default": "chat", "reduceMotion": true],
                     forKey: "jotbloom.panel.preferences.v1")
        let store = PanelPreferencesStore(defaults: defaults)
        var value = store.load()
        XCTAssertEqual(value.appearance, .dark)
        XCTAssertEqual(value.defaultSlot, .chat)
        XCTAssertTrue(value.reduceMotion)
        let originalOrder = value.order
        for appearance in [PanelAppearance.light, .dark] {
            value.appearance = appearance
            store.save(value)
            let reloaded = PanelPreferencesStore(defaults: defaults).load()
            XCTAssertEqual(reloaded.appearance, appearance)
            XCTAssertEqual(reloaded.order, originalOrder)
            XCTAssertEqual(reloaded.defaultSlot, .chat)
            XCTAssertTrue(reloaded.reduceMotion)
        }
    }

}
