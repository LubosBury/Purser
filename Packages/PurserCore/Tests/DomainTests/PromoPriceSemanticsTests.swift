import Foundation
import Testing
import Domain

@Suite struct PromoPriceSemanticsTests {
    let existing = [
        NewPromoPrice(territory: "USA", pricePointId: "pp-usa-1"),
        NewPromoPrice(territory: "CZE", pricePointId: "pp-cze-1"),
        NewPromoPrice(territory: "DEU", pricePointId: "pp-deu-1"),
    ]
    let patch = [NewPromoPrice(territory: "USA", pricePointId: "pp-usa-2")]

    @Test func replaceSemanticsKeepsOnlyThePatch() {
        let result = PromoPriceSemantics.applyPatch(existing: existing, patch: patch, replaces: true)
        #expect(result == [NewPromoPrice(territory: "USA", pricePointId: "pp-usa-2")])
    }

    @Test func mergeSemanticsOverridesByTerritoryAndSorts() {
        let result = PromoPriceSemantics.applyPatch(existing: existing, patch: patch, replaces: false)
        #expect(result.map(\.territory) == ["CZE", "DEU", "USA"])
        #expect(result.first { $0.territory == "USA" }?.pricePointId == "pp-usa-2")
        #expect(result.first { $0.territory == "CZE" }?.pricePointId == "pp-cze-1")
    }

    func offer(mode: OfferMode, prices: [PromoPrice], ascId: String = "o1") -> PromoOffer {
        PromoOffer(ascId: ascId, subscriptionId: "s1", offerCode: "spring_v1", name: "Spring", mode: mode,
                   duration: .oneMonth, numberOfPeriods: 1, planType: .upfront, prices: prices)
    }

    @Test func matchIgnoresAscIdsAndCustomerPrices() {
        let live = offer(mode: .payUpFront, prices: [PromoPrice(ascId: "row-9", territory: "USA", pricePointId: "pp-usa-1", customerPrice: 4.99)])
        let target = offer(mode: .payUpFront, prices: [PromoPrice(ascId: nil, territory: "USA", pricePointId: "pp-usa-1", customerPrice: nil)], ascId: "o1")
        #expect(PromoPriceSemantics.matches(live: live, target: target))
    }

    @Test func freeTrialRowsCompareWithoutPricePoint() {
        let live = offer(mode: .freeTrial, prices: [PromoPrice(ascId: "r1", territory: "USA", pricePointId: "pp-zero", customerPrice: 0)])
        let target = offer(mode: .freeTrial, prices: [PromoPrice(ascId: nil, territory: "USA", pricePointId: nil, customerPrice: nil)])
        #expect(PromoPriceSemantics.matches(live: live, target: target))
    }

    @Test func differentPointOrMissingTerritoryDoesNotMatch() {
        let target = offer(mode: .payUpFront, prices: [
            PromoPrice(ascId: nil, territory: "USA", pricePointId: "pp-usa-1", customerPrice: nil),
            PromoPrice(ascId: nil, territory: "CZE", pricePointId: "pp-cze-1", customerPrice: nil),
        ])
        let wrongPoint = offer(mode: .payUpFront, prices: [
            PromoPrice(ascId: "a", territory: "USA", pricePointId: "pp-usa-2", customerPrice: nil),
            PromoPrice(ascId: "b", territory: "CZE", pricePointId: "pp-cze-1", customerPrice: nil),
        ])
        let missing = offer(mode: .payUpFront, prices: [PromoPrice(ascId: "a", territory: "USA", pricePointId: "pp-usa-1", customerPrice: nil)])
        #expect(!PromoPriceSemantics.matches(live: wrongPoint, target: target))
        #expect(!PromoPriceSemantics.matches(live: missing, target: target))
    }

    @Test func deletedOfferMatchesNilTarget() {
        #expect(PromoPriceSemantics.matches(live: nil, target: nil))
        #expect(!PromoPriceSemantics.matches(live: offer(mode: .payUpFront, prices: []), target: nil))
        #expect(!PromoPriceSemantics.matches(live: nil, target: offer(mode: .payUpFront, prices: [])))
    }
}
