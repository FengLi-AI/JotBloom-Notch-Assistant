import Foundation

/// One native drag has one destination, even if AppKit repeats its drop callback.
public struct AssistantDropSession {
    public enum Destination: Equatable { case notch, assistant }
    public private(set) var sequence: Int?
    private var completed: [(Int, Destination)] = []
    public init() {}
    @discardableResult public mutating func begin(_ value: Int) -> Bool {
        guard !completed.contains(where: { $0.0 == value }) else { return false }
        sequence = value; return true
    }
    public func destination(for value: Int) -> Destination? { completed.first { $0.0 == value }?.1 }
    @discardableResult public mutating func commit(_ value: Int, to destination: Destination) -> Bool {
        guard sequence == value, self.destination(for: value) == nil else { return false }
        completed.append((value, destination)); if completed.count > 64 { completed.removeFirst() }
        sequence = nil; return true
    }
    public mutating func cancel() { sequence = nil }
}
