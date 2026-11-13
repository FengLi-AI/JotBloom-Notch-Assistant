import Foundation

public enum TaskWatchdog {
    public enum Alert: Equatable { case stalled, overtime }
    public static func check(activeSeconds: TimeInterval, idleSeconds: TimeInterval, waiting: Bool, sleeping: Bool, timeLimit: TimeInterval = 3600) -> Alert? {
        guard !waiting, !sleeping else { return nil }
        if activeSeconds >= timeLimit { return .overtime }
        if idleSeconds >= 600 { return .stalled }
        return nil
    }
}
