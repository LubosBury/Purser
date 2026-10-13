import Foundation
import Domain

/// Pure scheduling rules of the nightly read-only sync (spec §4 "In the background").
public enum NightlySchedule {
    /// Re-check interval of the scheduler loop; wake notifications add an extra check.
    public static let maxCheckInterval: TimeInterval = 15 * 60
    /// A nightly attempt that did not finish is retried after this long, not on every check.
    public static let retryAfter: TimeInterval = 60 * 60
    /// A plan in Applying with a heartbeat younger than this means the app is writing right now.
    public static let applyHeartbeatFreshness: TimeInterval = AppleConstants.heartbeatSeconds * 6

    static func clamp(_ hourUTC: Int) -> Int { min(max(hourUTC, 0), 23) }

    /// The latest instant hourUTC:00:00Z that is <= now.
    public static func lastSlot(before now: Date, hourUTC: Int) -> Date {
        let todaySlot = CalendarDate.today(now: now).startOfDayUTC.addingTimeInterval(TimeInterval(clamp(hourUTC) * 3600))
        return todaySlot <= now ? todaySlot : todaySlot.addingTimeInterval(-86_400)
    }

    /// The first instant hourUTC:00:00Z strictly after now.
    public static func nextSlot(after now: Date, hourUTC: Int) -> Date {
        lastSlot(before: now, hourUTC: hourUTC).addingTimeInterval(86_400)
    }

    /// Due when no sync finished (complete or partial) since the last slot and no attempt was made
    /// since the slot within `retryAfter`. A Mac asleep at the slot is therefore synced on the first check after wake.
    public static func isDue(now: Date, hourUTC: Int, lastFinishedSync: Date?, lastAttempt: Date?) -> Bool {
        let slot = lastSlot(before: now, hourUTC: hourUTC)
        if let lastFinishedSync, lastFinishedSync >= slot { return false }
        if let lastAttempt, lastAttempt >= slot, now.timeIntervalSince(lastAttempt) < retryAfter { return false }
        return true
    }

    public static func applyInProgress(heartbeats: [Date?], now: Date) -> Bool {
        heartbeats.contains { heartbeat in
            heartbeat.map { now.timeIntervalSince($0) < applyHeartbeatFreshness } ?? false
        }
    }

    /// Seconds until the next check: the nearest slot of any workspace, capped by `maxCheckInterval`, at least 1 s.
    public static func nextCheckDelay(now: Date, hoursUTC: [Int]) -> TimeInterval {
        let nearest = hoursUTC.map { nextSlot(after: now, hourUTC: $0).timeIntervalSince(now) }.min() ?? maxCheckInterval
        return max(1, min(nearest, maxCheckInterval))
    }
}
