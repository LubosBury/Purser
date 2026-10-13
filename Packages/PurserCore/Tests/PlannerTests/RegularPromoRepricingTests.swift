import Foundation
import Testing
import Domain
import Catalog
import Policy
@testable import Planner
import PurserTestSupport

/// O5 (M4): RegularPlanSpec.promoRepricing re-prices PAYG promo offers from the NEW regular price when it drops;
/// the PATCH goes through M1's addPromo(.reprice), so the regular POST depends on it (paygPromoPatches).
@Suite struct RegularPromoRepricingTests {
    func regular(_ usa: String, preserve: Bool?, repricing: [String: IntroPricing]) -> PlanSpec {
        .regular(RegularPlanSpec(subscriptionIds: ["s"], planType: .upfront,
                                 prices: [TerritoryAmount(territory: "USA", amount: d(usa))],
                                 startDate: today.adding(days: 7), preserveCurrentPrice: preserve,
                                 skipIntroReplacement: [:], filter: PlanFilter(), promoRepricing: repricing))
    }

    /// "s" costs 29.99 in USA, DEU and CZE (M1 `yearly`); the PAYG promo costs 19.99 everywhere.
    func catalog(promoMode: OfferMode = .payAsYouGo) -> SyntheticCatalog {
        var catalog = yearly(.readyToSubmit)
        catalog.addPromo("s", code: "payg", mode: promoMode, prices: ["USA": d("19.99"), "DEU": d("19.99"), "CZE": d("19.99")],
                         ascId: "po-payg")
        return catalog
    }

    @Test func decreaseRepricesPaygPromoBeforeTheRegularPost() throws {
        let draft = try plan(regular("24.99", preserve: nil, repricing: ["po-payg": .percentOfRegular(d("0.6"))]), catalog().snapshot())
        #expect(draft.ops == [.patchPrices, .post])
        #expect(draft.items[0].payload == .replacePromoPrices(ascId: "po-payg", prices: [
            NewPromoPrice(territory: "CZE", pricePointId: SyntheticCatalog.pointId("s", "CZE", .upfront, d("19.99"))),
            NewPromoPrice(territory: "DEU", pricePointId: SyntheticCatalog.pointId("s", "DEU", .upfront, d("19.99"))),
            NewPromoPrice(territory: "USA", pricePointId: SyntheticCatalog.pointId("s", "USA", .upfront, d("14.99"))),
        ]))
        #expect(draft.items[1].dependsOn == [1])
        #expect(draft.verdicts("O5").isEmpty)
        #expect(draft.blocks.isEmpty)
    }

    @Test func decreaseWithoutRepricingIsBlockedByO5() throws {
        let draft = try plan(regular("18.99", preserve: nil, repricing: [:]), catalog().snapshot())
        #expect(draft.verdicts("O5").contains { $0.severity == .block(.plan) })
    }

    @Test func increaseNeverTouchesThePromo() throws {
        let draft = try plan(regular("34.99", preserve: true, repricing: ["po-payg": .percentOfRegular(d("0.6"))]), catalog().snapshot())
        #expect(draft.ops == [.post])
    }

    @Test func nonPaygPromoIsNotRepricedAndWarns() throws {
        let draft = try plan(regular("24.99", preserve: nil, repricing: ["po-payg": .percentOfRegular(d("0.6"))]),
                             catalog(promoMode: .payUpFront).snapshot())
        #expect(draft.ops == [.post])
        #expect(draft.verdicts.contains { $0.severity == .warn && $0.message.contains("payg") && $0.message.contains("PAY_AS_YOU_GO") })
    }
}
