import Combine
import Foundation

@MainActor
public final class AssistantAgentSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published public var mode: AssistantPermissionMode { didSet { defaults.set(mode.rawValue, forKey: "assistant.permissionMode") } }
    @Published public var executable: String { didSet { defaults.set(executable, forKey: "assistant.codexExecutable") } }
    @Published public var outputParent: String { didSet { defaults.set(outputParent, forKey: "assistant.outputParent") } }
    @Published public var quiet: Bool { didSet { defaults.set(quiet, forKey: "assistant.quiet") } }
    @Published public var reminderDayBefore: Int { didSet { defaults.set(reminderDayBefore, forKey: "assistant.reminderDayBefore") } }
    @Published public var reminderSameDay: Int { didSet { defaults.set(reminderSameDay, forKey: "assistant.reminderSameDay") } }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AssistantPermissionMode(rawValue: defaults.string(forKey: "assistant.permissionMode") ?? "") ?? .balanced
        executable = defaults.string(forKey: "assistant.codexExecutable") ?? ""
        outputParent = defaults.string(forKey: "assistant.outputParent") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("萌生助手任务").path
        quiet = defaults.bool(forKey: "assistant.quiet")
        func minute(_ key: String, fallback: Int) -> Int {
            guard let value = defaults.object(forKey: key) as? Int, (0..<1440).contains(value) else { return fallback }
            return value
        }
        reminderDayBefore = minute("assistant.reminderDayBefore", fallback: 600)
        reminderSameDay = minute("assistant.reminderSameDay", fallback: 540)
    }
}

/// Main-actor registry shared with the legacy read-only completion monitor.
@MainActor public enum AssistantOwnedThreads {
    public static var ids: Set<String> = []
}
