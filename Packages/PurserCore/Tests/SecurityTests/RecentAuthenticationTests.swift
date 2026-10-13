import Foundation
import Testing
import PurserSecurity

@Suite struct RecentAuthenticationTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func nothingIsCoveredBeforeTheFirstSuccess() {
        #expect(!RecentAuthentication().covers(start))
    }

    @Test func aSuccessCoversTheFollowingWindowOnly() {
        var recent = RecentAuthentication(window: 60)
        recent.noteSuccess(at: start)
        #expect(recent.covers(start))
        #expect(recent.covers(start.addingTimeInterval(59)))
        #expect(!recent.covers(start.addingTimeInterval(60)))
        #expect(!recent.covers(start.addingTimeInterval(-1)))
    }

    @Test func invalidateForgetsTheSuccess() {
        var recent = RecentAuthentication()
        recent.noteSuccess(at: start)
        recent.invalidate()
        #expect(!recent.covers(start.addingTimeInterval(1)))
    }

    @Test func defaultWindowIsOneMinute() {
        #expect(RecentAuthentication.defaultWindow == 60)
    }
}
