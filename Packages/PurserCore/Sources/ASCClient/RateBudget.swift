import Foundation
import Domain

public struct RateLimitSnapshot: Hashable, Sendable {
    public var limit: Int
    public var remaining: Int
    public var observedAt: Date

    public init(limit: Int, remaining: Int, observedAt: Date) {
        self.limit = limit; self.remaining = remaining; self.observedAt = observedAt
    }

    /// Parses "user-hour-lim:3500;user-hour-rem:500;".
    public static func parse(_ header: String, at: Date) -> RateLimitSnapshot? {
        var values: [String: Int] = [:]
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let number = Int(parts[1]) { values[parts[0]] = number }
        }
        guard let limit = values["user-hour-lim"], let remaining = values["user-hour-rem"] else { return nil }
        return RateLimitSnapshot(limit: limit, remaining: remaining, observedAt: at)
    }
}

/// Paces requests: a rolling per-minute cap plus the hourly budget from `X-Rate-Limit`,
/// of which `AppleConstants.verifyBudgetShare` is reserved for reads (verify) and never spent by writes.
public actor RateBudget {
    private let maxPerMinute: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var sentAt: [Date] = []
    private var sentSinceSnapshot = 0
    public private(set) var latest: RateLimitSnapshot?

    public init(maxPerMinute: Int = AppleConstants.maxRequestsPerMinute,
                now: @escaping @Sendable () -> Date,
                sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.maxPerMinute = maxPerMinute
        self.now = now
        self.sleep = sleep
    }

    /// Waits until a request may be sent. `forVerify` may use the reserved verify share; writes may not.
    /// Throws `ASCError.rateLimited` when the hourly budget left is too small; the caller pauses (RATE).
    public func acquire(forVerify: Bool) async throws {
        if let latest {
            let left = latest.remaining - sentSinceSnapshot
            let floor = forVerify ? 0 : Self.reserve(limit: latest.limit)
            if left <= floor { throw ASCError.rateLimited }
        }
        while true {
            let current = now()
            sentAt.removeAll { current.timeIntervalSince($0) >= 60 }
            if sentAt.count < maxPerMinute {
                sentAt.append(current)
                sentSinceSnapshot += 1
                return
            }
            let wait = max(0.001, 60 - current.timeIntervalSince(sentAt[0]))
            try await sleep(.milliseconds(Int64((wait * 1000).rounded(.up))))
        }
    }

    public func record(_ snapshot: RateLimitSnapshot) {
        latest = snapshot
        sentSinceSnapshot = 0
    }

    static func reserve(limit: Int) -> Int {
        let share = NSDecimalNumber(decimal: AppleConstants.verifyBudgetShare).doubleValue
        return Int((Double(limit) * share).rounded(.up))
    }
}
