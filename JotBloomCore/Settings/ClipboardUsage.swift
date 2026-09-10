import Foundation
public struct ClipboardUsage: Equatable, Sendable {
    public let count: Int
    public let contentBytes: Int64
    public let diskBytes: Int64
}
