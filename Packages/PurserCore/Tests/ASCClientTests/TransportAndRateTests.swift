import Foundation
import Testing
@testable import ASCClient
import Domain
import PurserTestSupport

@Suite struct TransportAndRateTests {
    @Test(arguments: [URLError.Code.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                      .internationalRoamingOff, .dataNotAllowed])
    func errorsThatProveNothingWasSent(_ code: URLError.Code) {
        guard case let .network(_, maybeSent) = URLSessionTransport.map(URLError(code)) else {
            Issue.record("expected .network")
            return
        }
        #expect(maybeSent == false)
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .cancelled, .badServerResponse, .unknown,
                      .secureConnectionFailed, .serverCertificateUntrusted, .badURL])
    func errorsThatMayHaveReachedApple(_ code: URLError.Code) {
        guard case let .network(_, maybeSent) = URLSessionTransport.map(URLError(code)) else {
            Issue.record("expected .network")
            return
        }
        #expect(maybeSent == true)
    }

    @Test func theSessionOfTheASCTransportKeepsNoURLCache() {
        #expect(URLSessionTransport().configuration.urlCache == nil)
    }

    @Test func parsesRateLimitHeader() {
        let at = Date(timeIntervalSince1970: 1_791_547_200)
        #expect(RateLimitSnapshot.parse("user-hour-lim:3500;user-hour-rem:500;", at: at) == RateLimitSnapshot(limit: 3500, remaining: 500, observedAt: at))
        #expect(RateLimitSnapshot.parse("user-hour-rem:12;user-hour-lim:3600", at: at) == RateLimitSnapshot(limit: 3600, remaining: 12, observedAt: at))
        #expect(RateLimitSnapshot.parse("user-hour-lim:3500;", at: at) == nil)
        #expect(RateLimitSnapshot.parse("garbage", at: at) == nil)
    }

    @Test func minuteCapMakesTheNextRequestWait() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_791_547_200))
        let budget = RateBudget(maxPerMinute: 3, now: { clock.now() }, sleep: { try await clock.sleep($0) })
        for _ in 0..<3 { try await budget.acquire(forVerify: false) }
        #expect(clock.recordedSleeps.isEmpty)
        try await budget.acquire(forVerify: false)
        #expect(clock.recordedSleeps == [.seconds(60)])
        #expect(clock.now() == Date(timeIntervalSince1970: 1_791_547_260))
    }

    @Test func writesStopAtTheVerifyReserveButReadsContinue() async throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_791_547_200))
        let budget = RateBudget(maxPerMinute: 1000, now: { clock.now() }, sleep: { try await clock.sleep($0) })
        // limit 3500 -> reserve 350. 352 left: two more writes fit, the third would eat into the reserve.
        await budget.record(RateLimitSnapshot(limit: 3500, remaining: 352, observedAt: clock.now()))
        try await budget.acquire(forVerify: false)
        try await budget.acquire(forVerify: false)
        await #expect(throws: ASCError.rateLimited) { try await budget.acquire(forVerify: false) }
        try await budget.acquire(forVerify: true)
        await budget.record(RateLimitSnapshot(limit: 3500, remaining: 1, observedAt: clock.now()))
        try await budget.acquire(forVerify: true)
        await #expect(throws: ASCError.rateLimited) { try await budget.acquire(forVerify: true) }
        #expect(await budget.latest?.remaining == 1)
    }

    @Test func reserveIsTenPercentRoundedUp() {
        #expect(RateBudget.reserve(limit: 3500) == 350)
        #expect(RateBudget.reserve(limit: 3501) == 351)
    }
}
