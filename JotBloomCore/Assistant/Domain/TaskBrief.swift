import Foundation

public struct TaskQuestion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var kind: String
    public var options: [String]
    public init(id: String, text: String, kind: String, options: [String]) { self.id = id; self.text = text; self.kind = kind; self.options = options }
}
public struct TaskDeadline: Codable, Equatable, Sendable {
    public var date: String?
    public var time: String?
    public var ambiguous: Bool
}
public struct TaskBrief: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var deliverable: String
    public var requester: String
    public var deadline: TaskDeadline?
    public var remindAt: String?
    public var questions: [TaskQuestion]
    public var assumptions: [String]
    public var keywords: [String]
    public var doneCriteria: String
    public var approach: [String]
    public var needsWork: Bool
    public var needsCodex: Bool
    public var needsNetwork: Bool
}
public struct AssistantMaterial: Codable, Equatable, Identifiable, Sendable {
    public var attachment: AssistantAttachment
    public var selected: Bool
    public var available: Bool
    public var id: String { attachment.id }
    public init(_ attachment: AssistantAttachment, selected: Bool, available: Bool = true) {
        self.attachment = attachment; self.selected = selected; self.available = available
    }
}
public struct AssistantPlan: Codable, Equatable, Sendable {
    public var brief: TaskBrief
    public var dueAt: Int64?
    public var reminders: [Int64]
    /// Missing in pre-v12 plans. Those reminders retain the legacy auto source.
    public var reminderOrigins: [String: AssistantReminderOrigin]? = nil
    public var materials: [AssistantMaterial]
    public var autoFind = true
    public var allowCodex = false
    public var allowNetwork = false
    public var permissionMode: String? = nil
    public var workingDirectory: String?
    public var outputDirectory: String
}
/// Persisted only on an explicit Start click. Model output never writes this boundary.
public struct TaskScope: Codable, Equatable, Sendable {
    public var goal: String
    public var doneCriteria: String
    public var materials: [AssistantAttachment]
    public var autoFind: Bool
    public var allowCodex: Bool
    public var allowNetwork: Bool
    public var confirmedAnswers: [String]? = nil
    public var permissionMode: String? = nil
    public var workingDirectory: String?
    public var outputDirectory: String
}
public struct AssistantReminder: Equatable, Identifiable, Sendable {
    public let id: String
    public let taskID: String
    public let title: String
    public let fireAt: Int64
    public let state: String
    public var origin: AssistantReminderOrigin = .auto
}
public enum AssistantReminderOrigin: String, Codable, Sendable { case auto, user, explicit, agent }

extension AssistantPlan {
    public mutating func restrictCodex(to availability: AgentAvailability) {
        if !availability.ready { allowCodex = false }
    }
    public func reminderOrigin(at time: Int64) -> AssistantReminderOrigin { reminderOrigins?[String(time)] ?? .auto }
    public mutating func addReminder(_ time: Int64, origin: AssistantReminderOrigin) {
        if !reminders.contains(time) { reminders.append(time) }
        if reminderOrigins == nil { reminderOrigins = [:] }
        reminderOrigins?[String(time)] = origin
    }
    public mutating func removeReminder(at index: Int) {
        let time = reminders.remove(at: index)
        reminderOrigins?[String(time)] = nil
    }
    public mutating func editReminder(at index: Int, time: Int64) {
        reminderOrigins?[String(reminders[index])] = nil
        reminders[index] = time
        if reminderOrigins == nil { reminderOrigins = [:] }
        reminderOrigins?[String(time)] = .user
    }
    public func reminderIsAfterDeadline(_ time: Int64) -> Bool { dueAt.map { time > $0 } ?? false }
    /// Only replace automatic reminders. An explicitly emptied schedule stays off.
    public mutating func reschedule(due: Int64?, now: Int64, timeZone: TimeZone, dayBeforeMinute: Int, sameDayMinute: Int) {
        let generate = reminders.contains { reminderOrigin(at: $0) == .auto } || (dueAt == nil && reminders.isEmpty && due != nil)
        let retained = reminders.filter { reminderOrigin(at: $0) != .auto }
        reminderOrigins = Dictionary(uniqueKeysWithValues: Set(retained).map { (String($0), reminderOrigin(at: $0)) })
        reminders = retained; dueAt = due
        if generate {
            for time in AssistantDates.reminders(due: due, explicit: nil, now: now, timeZone: timeZone, dayBeforeMinute: dayBeforeMinute, sameDayMinute: sameDayMinute) where !reminders.contains(time) {
                addReminder(time, origin: .auto)
            }
        }
        reminders.sort()
    }
}
public struct UnderstandingInput: Sendable {
    public let text: String
    public let filenames: [String]
    public let history: [ChatTurn]
    public let answers: [String]
    public let now: Date
    public let timeZone: TimeZone
    public var questionRounds: Int = 0
}
public enum AssistantIntent: Equatable, Sendable { case chat, task, note(String) }
public enum AssistantChatResult { case chat, handled(ChatTurn, noteID: Int64?) }

public enum AssistantDates {
    public static func parse(_ text: String, timeZone: TimeZone) -> Int64? {
        let format = text.count == 10 ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone
        formatter.dateFormat = format; formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
    public static func deadline(_ value: TaskDeadline?, timeZone: TimeZone) -> Int64? {
        guard let date = value?.date, value?.ambiguous == false else { return nil }
        return parse(date + "T" + (value?.time ?? "18:00"), timeZone: timeZone)
    }
    public static func reminders(due: Int64?, explicit: Int64?, now: Int64, timeZone: TimeZone,
                                 dayBeforeMinute: Int = 600, sameDayMinute: Int = 540) -> [Int64] {
        if let explicit { return explicit > now ? [explicit] : [] }
        guard let due, due > now else { return [] }
        let hour: Int64 = 3_600_000
        if due - now < 24 * hour {
            let value = due - (due - now < 2 * hour ? 900_000 : 2 * hour)
            return value > now ? [value] : []
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(due) / 1000)
        let day = calendar.startOfDay(for: date)
        let previous = calendar.date(byAdding: .day, value: -1, to: day)!
        let before = (0..<1440).contains(dayBeforeMinute) ? dayBeforeMinute : 600
        let same = (0..<1440).contains(sameDayMinute) ? sameDayMinute : 540
        return [calendar.date(bySettingHour: before / 60, minute: before % 60, second: 0, of: previous),
                calendar.date(bySettingHour: same / 60, minute: same % 60, second: 0, of: day)]
            .compactMap { $0 }.map { Int64($0.timeIntervalSince1970 * 1000) }.filter { $0 > now && $0 < due }.sorted()
    }
    public static func text(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日（EEEE）HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}
public enum TaskBriefValidator {
    public static func json(_ text: String) -> Data {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), value.hasSuffix("```"), let first = value.firstIndex(of: "\n") {
            value = String(value[value.index(after: first)..<value.index(value.endIndex, offsetBy: -3)])
        }
        return Data(value.utf8)
    }
    public static func parse(_ text: String, timeZone: TimeZone = .current) throws -> TaskBrief {
        let brief = try JSONDecoder().decode(TaskBrief.self, from: json(text))
        try validate(brief, timeZone: timeZone); return brief
    }
    public static func validate(_ brief: TaskBrief, timeZone: TimeZone) throws {
        guard !brief.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, brief.title.count <= 30,
              brief.approach.count <= 5, brief.approach.allSatisfy({ $0.count <= 40 }),
              brief.doneCriteria.count <= 80, !brief.needsWork || !brief.doneCriteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              brief.questions.count <= 3, Set(brief.questions.map(\.id)).count == brief.questions.count,
              brief.questions.allSatisfy({ !$0.id.isEmpty && !$0.text.isEmpty && ["single", "multi", "text"].contains($0.kind) && $0.options.count <= 8 }),
              brief.keywords.count <= 5 else { throw SettingsError.responseInvalid }
        if let date = brief.deadline?.date, AssistantDates.parse(date, timeZone: timeZone) == nil { throw SettingsError.responseInvalid }
        if let time = brief.deadline?.time, AssistantDates.parse("2000-01-01T" + time, timeZone: timeZone) == nil { throw SettingsError.responseInvalid }
        if let remind = brief.remindAt, AssistantDates.parse(remind, timeZone: timeZone) == nil { throw SettingsError.responseInvalid }
        if brief.deadline?.ambiguous == true && brief.questions.isEmpty { throw SettingsError.responseInvalid }
    }
}
public enum IntentResultValidator {
    public static func parse(_ text: String, input: String, allowNote: Bool) -> AssistantIntent {
        struct Result: Decodable { let intent: String; let confidence: String; let noteText: String? }
        guard let value = try? JSONDecoder().decode(Result.self, from: TaskBriefValidator.json(text)), value.confidence == "high" else { return .chat }
        if value.intent == "task" { return .task }
        if value.intent == "note", allowNote {
            let note = value.noteText ?? ""
            return .note(!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && input.contains(note) ? note : input)
        }
        return .chat
    }
}

public enum AssistantOutputLocation {
    public static func suggested(title: String, now: Date, reserved: [String], parentPath: String? = nil) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let safe = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":" }
        let base = String((formatter.string(from: now) + "-" + String(String.UnicodeScalarView(safe))).prefix(60))
        let parent = parentPath.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("萌生助手任务")
        var candidate = parent.appendingPathComponent(base).path, suffix = 2
        while reserved.contains(candidate) || FileManager.default.fileExists(atPath: candidate) {
            let ending = "-\(suffix)"; candidate = parent.appendingPathComponent(String(base.prefix(60 - ending.count)) + ending).path; suffix += 1
        }
        return candidate
    }
}
