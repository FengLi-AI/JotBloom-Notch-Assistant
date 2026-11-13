import XCTest
@testable import JotBloomCore

@MainActor
final class AssistantPreferencesTests: XCTestCase {
    func testDefaultsAndPersistedChangesStayInTheirOwnSuite() {
        let name = "JotBloom.M6.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AssistantAgentSettings(defaults: defaults)
        XCTAssertFalse(settings.quiet); XCTAssertEqual(settings.reminderDayBefore, 600); XCTAssertEqual(settings.reminderSameDay, 540)
        settings.quiet = true; settings.reminderDayBefore = 1130; settings.reminderSameDay = 435
        let reopened = AssistantAgentSettings(defaults: defaults)
        XCTAssertTrue(reopened.quiet); XCTAssertEqual(reopened.reminderDayBefore, 1130); XCTAssertEqual(reopened.reminderSameDay, 435)
        defaults.set(-3, forKey: "assistant.reminderDayBefore"); defaults.set(1440, forKey: "assistant.reminderSameDay")
        let recovered = AssistantAgentSettings(defaults: defaults)
        XCTAssertEqual(recovered.reminderDayBefore, 600); XCTAssertEqual(recovered.reminderSameDay, 540)
    }
    func testCustomReminderTimesAndEarlyDeadlineNeverScheduleAfterDeadline() throws {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        func time(_ value: String) -> Int64 { AssistantDates.parse(value, timeZone: zone)! }
        let now = time("2026-11-10T08:00"), due = time("2026-11-13T08:00")
        let custom = AssistantDates.reminders(due: due, explicit: nil, now: now, timeZone: zone, dayBeforeMinute: 18 * 60 + 30, sameDayMinute: 7 * 60 + 15)
        XCTAssertEqual(custom, [time("2026-11-12T18:30"), time("2026-11-13T07:15")])
        XCTAssertEqual(AssistantDates.reminders(due: due, explicit: nil, now: now, timeZone: zone), [time("2026-11-12T10:00")])
    }
    func testExplicitAndNearDeadlineRulesOverrideCustomDefaults() {
        let zone = TimeZone(secondsFromGMT: 0)!, now: Int64 = 1_800_000_000_000
        let explicit = now + 30_000
        XCTAssertEqual(AssistantDates.reminders(due: nil, explicit: explicit, now: now, timeZone: zone, dayBeforeMinute: 1, sameDayMinute: 2), [explicit])
        XCTAssertEqual(AssistantDates.reminders(due: now + 6 * 3_600_000, explicit: nil, now: now, timeZone: zone, dayBeforeMinute: 1, sameDayMinute: 2), [now + 4 * 3_600_000])
        XCTAssertEqual(AssistantDates.reminders(due: now + 3_600_000, explicit: nil, now: now, timeZone: zone), [now + 2_700_000])
        XCTAssertTrue(AssistantDates.reminders(due: now + 300_000, explicit: nil, now: now, timeZone: zone).isEmpty)
    }
    func testReminderUsesLocalCalendarAcrossDaylightSaving() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        func time(_ value: String) -> Int64 { AssistantDates.parse(value, timeZone: zone)! }
        let values = AssistantDates.reminders(due: time("2027-03-14T18:00"), explicit: nil, now: time("2027-03-12T08:00"), timeZone: zone)
        XCTAssertEqual(values, [time("2027-03-13T10:00"), time("2027-03-14T09:00")])
        XCTAssertEqual(values[1] - values[0], 22 * 3_600_000)
    }
}
