import Foundation

/// Synchronous cancellation fence: image normalization may be running on the service actor.
public final class CapturePermission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var generation: UInt64 = 0
    public init() {}
    public func setAllowed(_ value: Bool) { lock.lock(); generation &+= 1; allowed = value; lock.unlock() }
    public var isAllowed: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    public var token: UInt64? { lock.lock(); defer { lock.unlock() }; return allowed ? generation : nil }
    public func commit<T>(token: UInt64, _ action: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard allowed, generation == token else { return nil }
        return try action()
    }
}
