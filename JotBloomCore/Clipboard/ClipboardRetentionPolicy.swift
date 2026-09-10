import Foundation

public struct ClipboardRetentionPolicy: Equatable, Sendable {
    public static let defaultMaximumBytes: Int64 = 2_000_000_000

    public static let stageThreeDefault = ClipboardRetentionPolicy(
        maximumCount: 200,
        maximumAgeMilliseconds: nil,
        maximumBytes: defaultMaximumBytes
    )

    public let maximumCount: Int?
    public let maximumAgeMilliseconds: Int64?
    public let maximumBytes: Int64?

    public init(
        maximumCount: Int?,
        maximumAgeMilliseconds: Int64?,
        maximumBytes: Int64?
    ) {
        self.maximumCount = maximumCount.map { max(0, $0) }
        self.maximumAgeMilliseconds = maximumAgeMilliseconds.map { max(0, $0) }
        self.maximumBytes = maximumBytes.map { max(0, $0) }
    }
}

public enum ClipboardCleanupPlanner {
    public static func identifiersToDelete(
        from items: [ClipboardItem],
        policy: ClipboardRetentionPolicy,
        nowUTCms: Int64
    ) -> [Int64] {
        var survivors = items.sorted(by: oldestFirst)
        var identifiers: [Int64] = []

        if let maximumAge = policy.maximumAgeMilliseconds {
            let (candidateCutoff, underflow) = nowUTCms
                .subtractingReportingOverflow(maximumAge)
            let cutoff = underflow ? Int64.min : candidateCutoff
            let expiredCount = survivors.prefix { $0.copiedAtUTCms < cutoff }.count
            if expiredCount > 0 {
                identifiers.append(contentsOf: survivors.prefix(expiredCount).map(\.id))
                survivors.removeFirst(expiredCount)
            }
        }

        if let maximumCount = policy.maximumCount,
           survivors.count > maximumCount {
            let overflow = survivors.count - maximumCount
            identifiers.append(contentsOf: survivors.prefix(overflow).map(\.id))
            survivors.removeFirst(overflow)
        }

        if let maximumBytes = policy.maximumBytes {
            var totalBytes = survivors.reduce(Int64(0)) {
                addingWithoutOverflow($0, $1.contentByteCount)
            }
            if totalBytes > maximumBytes {
                let target = maximumBytes / 2
                while totalBytes > target, let oldest = survivors.first {
                    identifiers.append(oldest.id)
                    totalBytes = max(0, totalBytes - oldest.contentByteCount)
                    survivors.removeFirst()
                }
            }
        }

        return identifiers
    }

    private static func oldestFirst(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        if lhs.copiedAtUTCms == rhs.copiedAtUTCms {
            return lhs.id < rhs.id
        }
        return lhs.copiedAtUTCms < rhs.copiedAtUTCms
    }

    private static func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
