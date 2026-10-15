import Foundation
import Testing
import Domain
import Catalog
@testable import Policy
import PurserTestSupport

func promoCreate(_ seq: Int, sub: String = "s", code: String, mode: OfferMode = .payAsYouGo, prices: [TerritoryCode: Decimal?]) -> PlannedItem {
    let newPrices = prices.map { t, price in NewPromoPrice(territory: t, pricePointId: price.map { SyntheticCatalog.pointId(sub, t, .upfront, $0) }) }
    let offer = NewPromoOffer(subscriptionId: sub, offerCode: code, name: code, mode: mode, duration: .oneYear, numberOfPeriods: 1,
                              planType: .upfront, prices: newPrices)
    let target = PromoOffer(ascId: "", subscriptionId: sub, offerCode: code, name: code, mode: mode, duration: .oneYear,
                            numberOfPeriods: 1, planType: .upfront,
                            prices: prices.map { t, price in PromoPrice(ascId: nil, territory: t, pricePointId: price.map { SyntheticCatalog.pointId(sub, t, .upfront, $0) }, customerPrice: price) })
    return PlannedItem(seq: seq, cell: .promo(subscriptionId: sub, offerCode: code), payload: .createPromo(offer), before: .promo(nil), target: .promo(target))
}

@Suite struct PromoRulesTests {
    let all: [TerritoryCode: Decimal?] = ["USA": d("19.99"), "DEU": d("19.99"), "CZE": d("19.99")]

    @Test func o1() {
        var catalog = basicCatalog()
        catalog.addPromo("s", code: "winback", prices: ["USA": d("9.99")])
        let snapshot = catalog.snapshot()
        #expect(O1OfferCodeRule().evaluate(context(snapshot, [promoCreate(1, code: "spring", prices: all)])).isEmpty)
        let verdicts = O1OfferCodeRule().evaluate(context(snapshot, [promoCreate(1, code: "winback", prices: all)]))
        #expect(verdicts.map(\.severity) == [.block(.plan)])
        #expect(verdicts[0].message.contains("suggestion: winback_v2"))
        #expect(OfferCodeSuggester.suggest(for: "winback_v2", used: ["winback", "winback_v2"]) == "winback_v3")
        #expect(OfferCodeSuggester.suggest(for: "fresh", used: []) == "fresh")
    }

    @Test func o2() {
        var catalog = basicCatalog()
        for i in 0..<9 { catalog.addPromo("s", code: "c\(i)", prices: ["USA": d("9.99")]) }
        let nine = catalog.snapshot()
        #expect(O2PromoCountRule().evaluate(context(nine, [promoCreate(1, code: "new", prices: all)])).isEmpty)
        catalog.addPromo("s", code: "c9", prices: ["USA": d("9.99")])
        #expect(O2PromoCountRule().evaluate(context(catalog.snapshot(), [promoCreate(1, code: "new", prices: all)])).map(\.severity) == [.block(.plan)])
    }

    @Test func o3() {
        let snapshot = basicCatalog().snapshot()
        #expect(O3PromoCoverageRule().evaluate(context(snapshot, [promoCreate(1, code: "a", prices: all)])).isEmpty)
        let verdicts = O3PromoCoverageRule().evaluate(context(snapshot, [promoCreate(1, code: "a", prices: ["USA": d("19.99")])]))
        #expect(verdicts.map(\.severity) == [.block(.plan)])
        #expect(verdicts[0].message.contains("Prices are missing for 2 territories: CZE, DEU"))
    }

    @Test func o5PlanAfterRegularDecrease() {
        var catalog = basicCatalog()
        catalog.addPromo("s", code: "payg", prices: ["USA": d("19.99"), "DEU": d("19.99"), "CZE": d("19.99")])
        let snapshot = catalog.snapshot()
        let fine = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("24.99"), start: today.adding(days: 7), preserve: false)
        #expect(O5PromoBelowRegularRule().evaluate(context(snapshot, [fine])).isEmpty)
        let below = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("18.99"), start: today.adding(days: 7), preserve: false)
        let verdicts = O5PromoBelowRegularRule().evaluate(context(snapshot, [below]))
        #expect(verdicts.map(\.severity) == [.block(.plan)])
        #expect(verdicts[0].message.contains("USA (19.99 ≥ 18.99)"))
    }

    @Test func o5Invariant() {
        var catalog = basicCatalog()
        catalog.addPromo("s", code: "payg", prices: ["USA": d("19.99")])
        #expect(O5PromoBelowRegularRule().check(catalog.snapshot(), today: today).isEmpty)
        catalog.addPromo("s", code: "bad", prices: ["USA": d("29.99")])
        catalog.addPromo("s", code: "puf", mode: .payUpFront, prices: ["USA": d("39.99")])
        let verdicts = O5PromoBelowRegularRule().check(catalog.snapshot(), today: today)
        #expect(verdicts.map(\.severity) == [.block(.plan), .warn])
        #expect(verdicts[0].message == "The promo bad in USA: 29.99 is not cheaper than the regular price 29.99.")
    }

    @Test func o6AndO7() {
        var catalog = basicCatalog()
        catalog.addPromo("s", code: "old", prices: ["USA": d("19.99")])
        let snapshot = catalog.snapshot()
        let offer = snapshot.promoOffers[0]
        #expect(O6PromoChangeRule().evaluate(context(snapshot, [promoCreate(1, code: "a", prices: all)])).isEmpty)
        #expect(O7PromoDeleteRule().evaluate(context(snapshot, [promoCreate(1, code: "a", prices: all)])).isEmpty)
        let cell: CellKey = .promo(subscriptionId: "s", offerCode: "old")
        let delete = PlannedItem(seq: 1, cell: cell, payload: .deletePromo(ascId: offer.ascId), before: .promo(offer), target: .promo(nil))
        let reprice = PlannedItem(seq: 2, cell: cell, payload: .replacePromoPrices(ascId: offer.ascId, prices: [NewPromoPrice(territory: "USA", pricePointId: "x")]),
                                  before: .promo(offer), target: .promo(offer))
        #expect(O6PromoChangeRule().evaluate(context(snapshot, [delete, reprice])).map(\.severity) == [.confirm(.c2), .confirm(.c2)])
        #expect(O7PromoDeleteRule().evaluate(context(snapshot, [delete])).map(\.riskClass) == ["O7 promo offer deletion"])
    }
}

@Suite struct IAPRulesTests {
    func scheduleItem(_ snapshot: CatalogSnapshot, prices: [TerritoryCode: Decimal]) -> PlannedItem {
        let old = snapshot.iapSchedules["iap"]!
        let manual = prices.map { NewIAPManualPrice(territory: $0.key, pricePointId: SyntheticCatalog.pointId("iap", $0.key, nil, $0.value), startDate: nil, endDate: nil) }
        let target = IAPSchedule(iapId: "iap", scheduleId: old.scheduleId, baseTerritory: "USA",
                                 manualPrices: prices.map { IAPManualPrice(ascId: nil, territory: $0.key, pricePointId: SyntheticCatalog.pointId("iap", $0.key, nil, $0.value), startDate: nil, endDate: nil, customerPrice: $0.value) })
        return PlannedItem(seq: 1, cell: .iapSchedule(iapId: "iap"), payload: .replaceIAPSchedule(NewIAPSchedule(iapId: "iap", baseTerritory: "USA", manualPrices: manual)),
                           before: .iapSchedule(old), target: .iapSchedule(target))
    }

    func catalog() -> CatalogSnapshot {
        var catalog = basicCatalog()
        catalog.addIAP("iap", base: "USA", manual: ["USA": d("99.99"), "DEU": d("89.99")])
        return catalog.snapshot()
    }

    @Test func l2() {
        let snapshot = catalog()
        #expect(L2IAPGeneratedPricesRule().evaluate(context(snapshot, [])).isEmpty)
        let verdicts = L2IAPGeneratedPricesRule().evaluate(context(snapshot, [scheduleItem(snapshot, prices: ["USA": d("99.99"), "DEU": d("89.99")])]))
        #expect(verdicts.map(\.severity) == [.warn])
        #expect(verdicts[0].message.hasPrefix("1 territories without a manual price"))
    }

    @Test func l3() {
        let snapshot = catalog()
        #expect(L3IAPDecreaseRule().evaluate(context(snapshot, [scheduleItem(snapshot, prices: ["USA": d("79.99"), "DEU": d("89.99")])])).isEmpty)
        let verdicts = L3IAPDecreaseRule().evaluate(context(snapshot, [scheduleItem(snapshot, prices: ["USA": d("59.99"), "DEU": d("89.99")])]))
        #expect(verdicts.map(\.riskClass) == ["L3 IAP price decrease of > 30 %"])
        #expect(verdicts[0].message.contains("USA 99.99 → 59.99"))
    }
}

@Suite struct MonthlyRatioRuleTests {
    func catalog(monthly: Decimal) -> SyntheticCatalog {
        var catalog = basicCatalog(monthly: true)
        for t in ["USA", "DEU", "CZE"] as [TerritoryCode] { catalog.setRegular("s", t, monthly, planType: .monthly) }
        return catalog
    }

    @Test func r3Plan() {
        let snapshot = catalog(monthly: d("2.99")).snapshot()
        let ok = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("33.99"), start: today.adding(days: 7), preserve: true)
        #expect(R3MonthlyRatioRule().evaluate(context(snapshot, [ok])).isEmpty)
        let tooHigh = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("39.99"), start: today.adding(days: 7), preserve: true)
        let verdicts = R3MonthlyRatioRule().evaluate(context(snapshot, [tooHigh]))
        #expect(verdicts.map(\.severity) == [.block(.cell)])
        #expect(verdicts[0].message.contains("0.9 from \(today.adding(days: 7))"))
    }

    @Test func r3Invariant() {
        #expect(R3MonthlyRatioRule().check(catalog(monthly: d("2.99")).snapshot(), today: today).isEmpty)
        let verdicts = R3MonthlyRatioRule().check(catalog(monthly: d("4.99")).snapshot(), today: today)
        #expect(verdicts.count == 3)
        #expect(verdicts[0].message == "12 × monthly / yearly = 2; allowed is 1–1.5.")
    }
}

@Suite struct DefaultRegistrationTests {
    @Test func defaultsContainEveryRule() {
        let ids = Set(PolicyEngine.defaultPlanRules.map(\.id))
        #expect(ids == ["A2", "A3", "A4", "A5", "A6", "A7", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9",
                        "I2", "I4", "I5", "I6", "I7", "I8", "I9", "O1", "O2", "O3", "O5", "O6", "O7", "L2", "L3", "S10",
                        "N1", "N2", "N3", "N4", "N5"])
        #expect(PolicyEngine.defaultInvariants.map(\.id) == ["A6", "R3", "I4", "I5", "O5"])
        let config = SyntheticCatalog.config(mapping: SyntheticImport.mapping())
        #expect(PolicyEngine.invariants(for: config).map(\.id) == ["A6", "R3", "I4", "I5", "O5"])
    }
}
