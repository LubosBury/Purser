import Foundation
import Testing
import Domain
import ASCClient
import PurserTestSupport

/// FakeASC (M2) must behave like App Store Connect did in spikes S7 and S10.
@Suite("FakeASC follows spikes S7 and S10")
struct FakeASCSpikeAlignmentTests {
    @Test func promoPatchFollowsTheS7Constant() async throws {
        let h = try await ExecutorHarness.make()
        _ = try await h.initialSync()
        let offer = try await h.writer.createPromotionalOffer(NewPromoOffer(
            subscriptionId: "sub-y", offerCode: "align_v1", name: "Align", mode: .payUpFront, duration: .oneMonth, numberOfPeriods: 1,
            planType: .upfront, prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-sub-y-USA-3"),
                                         NewPromoPrice(territory: "CZE", pricePointId: "pp-sub-y-CZE-3")]))
        try await h.writer.replacePromotionalOfferPrices(ascId: offer.ascId,
                                                         prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-sub-y-USA-2")])
        let snapshot = try await h.initialSync()
        let live = try #require(snapshot.promoOffers(subscriptionId: "sub-y").first { $0.offerCode == "align_v1" })
        #expect(live.prices.map(\.territory) == (AppleConstants.promoPatchReplacesPriceSet ? ["USA"] : ["CZE", "USA"]))
        #expect(live.prices.first { $0.territory == "USA" }?.pricePointId == "pp-sub-y-USA-2")
    }

    @Test func reusedOfferCodeAnswersWithTheRecordedError() async throws {
        let h = try await ExecutorHarness.make()
        let offer = NewPromoOffer(subscriptionId: "sub-y", offerCode: "reuse_v1", name: "Reuse", mode: .freeTrial, duration: .oneMonth,
                                  numberOfPeriods: 1, planType: .upfront, prices: [NewPromoPrice(territory: "USA", pricePointId: nil)])
        let created = try await h.writer.createPromotionalOffer(offer)
        try await h.writer.deletePromotionalOffer(ascId: created.ascId)
        do {
            _ = try await h.writer.createPromotionalOffer(offer)
            Issue.record("expected a 409 for a reused offer code")
        } catch let ASCError.http(status, code, _, detail) {
            #expect(status == 409)
            #expect(code == FakeASC.offerCodeReuseError.code)
            #expect(detail == FakeASC.offerCodeReuseError.detail)
        }
    }

    @Test(arguments: [false, true])
    func iapNullStartEchoFollowsTheS10Setting(echo: Bool) async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setIAPNullStartEchoesCreationDay(echo)
        try await h.writer.replaceIAPPriceSchedule(NewIAPSchedule(iapId: "iap-life", baseTerritory: "USA", manualPrices: [
            NewIAPManualPrice(territory: "USA", pricePointId: "pp-iap-life-USA-24", startDate: nil, endDate: nil),
        ]))
        let schedule = try #require(try await h.reader.iapPriceSchedule(iapId: "iap-life"))
        #expect(schedule.manualPrices.map(\.startDate) == [echo ? h.today : nil])
    }
}
