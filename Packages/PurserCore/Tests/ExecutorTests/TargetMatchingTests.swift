import Foundation
import Testing
import Domain
@testable import Executor

@Suite struct TargetMatchingTests {
    let today = CalendarDate(year: 2030, month: 3, day: 1)

    func offer(_ point: String, ascId: String = "") -> PromoOffer {
        PromoOffer(ascId: ascId, subscriptionId: "sub-1", offerCode: "spring_v1", name: "Spring", mode: .payUpFront,
                   duration: .oneMonth, numberOfPeriods: 1, planType: .upfront,
                   prices: [PromoPrice(ascId: nil, territory: "USA", pricePointId: point, customerPrice: nil)])
    }

    func scheduleItem() -> PlannedItem {
        let target = NewIAPSchedule(iapId: "iap-1", baseTerritory: "USA",
                                    manualPrices: [NewIAPManualPrice(territory: "USA", pricePointId: "lp-1", startDate: nil, endDate: nil)])
        return PlannedItem(seq: 1, cell: .iapSchedule(iapId: "iap-1"), payload: .replaceIAPSchedule(target),
                           before: .iapSchedule(nil), target: .iapSchedule(nil))
    }

    /// What ASC returns when the creation day is echoed for a manual price sent with `startDate: null` (spike S10).
    func echoedSchedule() -> IAPSchedule {
        IAPSchedule(iapId: "iap-1", scheduleId: "sched-7", baseTerritory: "USA", manualPrices: [
            IAPManualPrice(ascId: "m", territory: "USA", pricePointId: "lp-1", startDate: today, endDate: nil, customerPrice: 9.99),
        ])
    }

    @Test func repricedPromoIsReachedWhenPointsMatch() {
        let item = PlannedItem(seq: 1, cell: .promo(subscriptionId: "sub-1", offerCode: "spring_v1"),
                               payload: .replacePromoPrices(ascId: "o1", prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-2")]),
                               before: .promo(offer("pp-1", ascId: "o1")), target: .promo(offer("pp-2", ascId: "o1")))
        #expect(TargetMatching.promoOrIAPTargetReached(item, live: .promo(offer("pp-2", ascId: "o1")), today: today) == true)
        #expect(TargetMatching.promoOrIAPTargetReached(item, live: .promo(offer("pp-1", ascId: "o1")), today: today) == false)
    }

    @Test func deletedPromoIsReachedWhenGone() {
        let item = PlannedItem(seq: 1, cell: .promo(subscriptionId: "sub-1", offerCode: "spring_v1"),
                               payload: .deletePromo(ascId: "o1"), before: .promo(offer("pp-1", ascId: "o1")), target: .promo(nil))
        #expect(TargetMatching.promoOrIAPTargetReached(item, live: .promo(nil), today: today) == true)
    }

    @Test func iapScheduleUsesScheduleSemantics() {
        #expect(TargetMatching.promoOrIAPTargetReached(scheduleItem(), live: .iapSchedule(echoedSchedule()), today: today) == true)
    }

    @Test func otherCellsAreLeftToTheNaturalKey() {
        let item = PlannedItem(seq: 1, cell: .intro(subscriptionId: "sub-1", territory: "USA", planType: .upfront),
                               payload: .deleteIntro(ascId: "i1"), before: .intro(current: nil, future: nil), target: .intro(current: nil, future: nil))
        #expect(TargetMatching.promoOrIAPTargetReached(item, live: .intro(current: nil, future: nil), today: today) == nil)
    }

    @Test func reconcilerResolvesAnEchoedIAPStartDateAsTargetFound() {
        let item = scheduleItem()
        let live = CellState.iapSchedule(echoedSchedule())
        #expect(!Reconciler.isSatisfied(item.payload, live: live, today: today))
        #expect(Reconciler.reached(item, live: live, today: today))
        #expect(Reconciler.resolve(item, live: live, today: today) == .targetFound(ascId: "sched-7"))
    }
}
