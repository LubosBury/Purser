import Foundation
import Testing
@testable import Background

@Suite struct NightlyScheduleTests {
    static func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func lastSlotIsTodayOnceTheHourPassedElseYesterday() {
        #expect(NightlySchedule.lastSlot(before: Self.at("2030-03-02T02:59:59Z"), hourUTC: 3) == Self.at("2030-03-01T03:00:00Z"))
        #expect(NightlySchedule.lastSlot(before: Self.at("2030-03-02T03:00:00Z"), hourUTC: 3) == Self.at("2030-03-02T03:00:00Z"))
        #expect(NightlySchedule.lastSlot(before: Self.at("2030-03-02T23:10:00Z"), hourUTC: 23) == Self.at("2030-03-02T23:00:00Z"))
    }

    @Test func nextSlotIsStrictlyAfterNow() {
        #expect(NightlySchedule.nextSlot(after: Self.at("2030-03-02T02:00:00Z"), hourUTC: 3) == Self.at("2030-03-02T03:00:00Z"))
        #expect(NightlySchedule.nextSlot(after: Self.at("2030-03-02T03:00:00Z"), hourUTC: 3) == Self.at("2030-03-03T03:00:00Z"))
    }

    @Test func hourIsClampedToADay() {
        #expect(NightlySchedule.lastSlot(before: Self.at("2030-03-02T12:00:00Z"), hourUTC: 99) == Self.at("2030-03-01T23:00:00Z"))
        #expect(NightlySchedule.lastSlot(before: Self.at("2030-03-02T12:00:00Z"), hourUTC: -4) == Self.at("2030-03-02T00:00:00Z"))
    }

    @Test func dueWhenNothingFinishedSinceTheSlot() {
        let now = Self.at("2030-03-02T03:30:00Z")
        #expect(NightlySchedule.isDue(now: now, hourUTC: 3, lastFinishedSync: nil, lastAttempt: nil))
        #expect(NightlySchedule.isDue(now: now, hourUTC: 3, lastFinishedSync: Self.at("2030-03-01T03:10:00Z"), lastAttempt: nil))
        #expect(!NightlySchedule.isDue(now: now, hourUTC: 3, lastFinishedSync: Self.at("2030-03-02T03:05:00Z"), lastAttempt: nil))
    }

    @Test func firstWakeAfterTheSlotIsDue() {
        let wake = Self.at("2030-03-02T08:12:00Z")
        #expect(NightlySchedule.isDue(now: wake, hourUTC: 3, lastFinishedSync: Self.at("2030-03-01T09:00:00Z"), lastAttempt: nil))
    }

    @Test func failedAttemptIsRetriedAfterAnHourOnly() {
        let attempt = Self.at("2030-03-02T03:00:30Z")
        let last = Self.at("2030-03-01T03:05:00Z")
        #expect(!NightlySchedule.isDue(now: Self.at("2030-03-02T03:40:00Z"), hourUTC: 3, lastFinishedSync: last, lastAttempt: attempt))
        #expect(NightlySchedule.isDue(now: Self.at("2030-03-02T04:01:00Z"), hourUTC: 3, lastFinishedSync: last, lastAttempt: attempt))
        #expect(NightlySchedule.isDue(now: Self.at("2030-03-02T03:40:00Z"), hourUTC: 3, lastFinishedSync: last, lastAttempt: Self.at("2030-03-02T02:59:00Z")))
    }

    @Test func freshHeartbeatMeansApplyInProgress() {
        let now = Self.at("2030-03-02T03:30:00Z")
        #expect(NightlySchedule.applyInProgress(heartbeats: [Self.at("2030-03-02T03:29:50Z")], now: now))
        #expect(!NightlySchedule.applyInProgress(heartbeats: [Self.at("2030-03-02T03:10:00Z"), nil], now: now))
        #expect(!NightlySchedule.applyInProgress(heartbeats: [], now: now))
    }

    @Test func nextCheckDelayIsTheNearestSlotCappedAtFifteenMinutes() {
        #expect(NightlySchedule.nextCheckDelay(now: Self.at("2030-03-02T02:55:00Z"), hoursUTC: [3, 5]) == 300)
        #expect(NightlySchedule.nextCheckDelay(now: Self.at("2030-03-02T01:00:00Z"), hoursUTC: [3]) == NightlySchedule.maxCheckInterval)
        #expect(NightlySchedule.nextCheckDelay(now: Self.at("2030-03-02T01:00:00Z"), hoursUTC: []) == NightlySchedule.maxCheckInterval)
    }
}
