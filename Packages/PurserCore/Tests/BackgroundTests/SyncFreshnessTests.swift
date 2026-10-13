import Foundation
import Testing
@testable import Background

@Suite struct SyncFreshnessTests {
    static func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    let now = at("2030-03-03T12:00:00Z")

    @Test func staleAfterThirtySixHours() {
        #expect(SyncFreshness.isStale(lastCompleteSync: nil, now: now))
        #expect(!SyncFreshness.isStale(lastCompleteSync: Self.at("2030-03-02T01:00:00Z"), now: now))
        #expect(SyncFreshness.isStale(lastCompleteSync: Self.at("2030-03-01T23:00:00Z"), now: now))
    }

    @Test func staleNoticeOncePerDayPerEpisode() {
        let old = Self.at("2030-03-01T00:00:00Z")
        #expect(SyncFreshness.shouldNotifyStale(lastCompleteSync: old, lastNotified: nil, now: now))
        #expect(!SyncFreshness.shouldNotifyStale(lastCompleteSync: old, lastNotified: Self.at("2030-03-03T10:00:00Z"), now: now))
        #expect(SyncFreshness.shouldNotifyStale(lastCompleteSync: old, lastNotified: Self.at("2030-03-02T11:00:00Z"), now: now))
        #expect(!SyncFreshness.shouldNotifyStale(lastCompleteSync: Self.at("2030-03-03T03:00:00Z"), lastNotified: nil, now: now))
    }

    @Test func newEpisodeNotifiesEvenRightAfterAnOldNotice() {
        let notified = Self.at("2030-03-03T11:00:00Z")
        let completeAfterNotice = Self.at("2030-03-03T11:30:00Z")
        let later = Self.at("2030-03-05T00:00:00Z")
        #expect(SyncFreshness.shouldNotifyStale(lastCompleteSync: completeAfterNotice, lastNotified: notified, now: later))
    }
}
