import Foundation

/// "The last full sync is older than 36 h" notification rules.
public enum SyncFreshness {
    public static let staleAfter: TimeInterval = 36 * 3600
    public static let renotifyAfter: TimeInterval = 24 * 3600

    public static func isStale(lastCompleteSync: Date?, now: Date) -> Bool {
        guard let lastCompleteSync else { return true }
        return now.timeIntervalSince(lastCompleteSync) > staleAfter
    }

    /// At most one notice per day while stale; a notice older than the last complete sync starts a new episode.
    public static func shouldNotifyStale(lastCompleteSync: Date?, lastNotified: Date?, now: Date) -> Bool {
        guard isStale(lastCompleteSync: lastCompleteSync, now: now) else { return false }
        guard let lastNotified else { return true }
        if let lastCompleteSync, lastNotified < lastCompleteSync { return true }
        return now.timeIntervalSince(lastNotified) >= renotifyAfter
    }
}
