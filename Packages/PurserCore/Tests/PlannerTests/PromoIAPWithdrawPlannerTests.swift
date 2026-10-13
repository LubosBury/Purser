import Foundation
import Testing
import Domain
import Store
import Catalog
import Importer
import Policy
@testable import Planner
import PurserTestSupport

@Suite struct PromoPlannerTests {
    @Test func createPricesEveryAvailableTerritory() throws {
        let spec = PlanSpec.promo(PromoPlanSpec(action: .create(subscriptionId: "s", offerCode: "spring", name: "Spring", mode: .payAsYouGo,
                                                                duration: .oneYear, numberOfPeriods: 1, pricing: .percentOfRegular(d("0.5")))))
        let draft = try plan(spec, yearly().snapshot())
        #expect(draft.ops == [.post])
        guard case let .createPromo(offer) = draft.items[0].payload else { Issue.record("payload"); return }
        #expect(offer.prices.map(\.territory) == ["CZE", "DEU", "USA"])
        // 0.5 x 29.99 = 14.995 -> 14.99
        #expect(offer.prices.allSatisfy { $0.pricePointId?.hasSuffix("|14.99") == true })
        #expect(draft.blocks.isEmpty)
    }

    @Test func freeTrialPromoRowsHaveNoPricePoint() throws {
        let spec = PlanSpec.promo(PromoPlanSpec(action: .create(subscriptionId: "s", offerCode: "trial", name: "Trial", mode: .freeTrial,
                                                                duration: .oneMonth, numberOfPeriods: 1, pricing: .freeTrial)))
        let draft = try plan(spec, yearly().snapshot())
        guard case let .createPromo(offer) = draft.items.first?.payload else { Issue.record("payload"); return }
        #expect(offer.prices.allSatisfy { $0.pricePointId == nil })
    }

    @Test func usedCodeBlocksPlan() throws {
        var catalog = yearly()
        catalog.addPromo("s", code: "spring", prices: ["USA": d("9.99")])
        let spec = PlanSpec.promo(PromoPlanSpec(action: .create(subscriptionId: "s", offerCode: "spring", name: "Spring", mode: .payAsYouGo,
                                                                duration: .oneYear, numberOfPeriods: 1, pricing: .percentOfRegular(d("0.5")))))
        #expect(try plan(spec, catalog.snapshot()).verdicts("O1").map(\.severity) == [.block(.plan)])
    }

    @Test func repriceSendsFullSetAndKeepsUncoveredTerritories() throws {
        var catalog = yearly()
        catalog.addPromo("s", code: "payg", prices: ["USA": d("19.99"), "DEU": d("19.99"), "CZE": d("19.99")], ascId: "po-1")
        let spec = PlanSpec.promo(PromoPlanSpec(action: .reprice(offerAscId: "po-1", pricing: .table([TerritoryAmount(territory: "USA", amount: d("14.99"))]))))
        let draft = try plan(spec, catalog.snapshot())
        #expect(draft.ops == [.patchPrices])
        guard case let .replacePromoPrices(ascId, prices) = draft.items[0].payload else { Issue.record("payload"); return }
        #expect(ascId == "po-1")
        #expect(prices.map(\.territory) == ["CZE", "DEU", "USA"])
        #expect(prices.map { $0.pricePointId?.split(separator: "|").last.map(String.init) } == ["19.99", "19.99", "14.99"])
        #expect(draft.verdicts("O6").map(\.severity) == [.confirm(.c2)])
    }

    @Test func deleteNeedsConfirmationThatTheAppNoLongerUsesTheCode() throws {
        var catalog = yearly()
        catalog.addPromo("s", code: "old", prices: ["USA": d("9.99")], ascId: "po-old")
        let unconfirmed = try plan(.promo(PromoPlanSpec(action: .delete(offerAscId: "po-old", confirmedUnusedByApp: false))), catalog.snapshot())
        #expect(unconfirmed.ops == [.delete])
        #expect(unconfirmed.verdicts("O7").contains { $0.severity == .block(.plan) })
        let confirmed = try plan(.promo(PromoPlanSpec(action: .delete(offerAscId: "po-old", confirmedUnusedByApp: true))), catalog.snapshot())
        #expect(confirmed.blocks.isEmpty)
        #expect(confirmed.verdicts("O7").map(\.severity) == [.confirm(.c2)])
    }
}

@Suite struct IAPPlannerTests {
    func catalog() -> SyntheticCatalog {
        var catalog = yearly()
        catalog.addIAP("life", base: "USA", manual: ["USA": d("99.99"), "DEU": d("89.99")])
        catalog.addLadder(product: "life", territories: ["CZE"], planType: nil)
        func price(_ id: String, _ t: TerritoryCode, _ amount: String, start: CalendarDate?, end: CalendarDate?) -> IAPManualPrice {
            IAPManualPrice(ascId: id, territory: t, pricePointId: SyntheticCatalog.pointId("life", t, nil, d(amount)),
                           startDate: start, endDate: end, customerPrice: d(amount))
        }
        catalog.iapSchedules["life"] = IAPSchedule(iapId: "life", scheduleId: "sched-life", baseTerritory: "USA", manualPrices: [
            price("mp-usa", "USA", "99.99", start: nil, end: nil),
            price("mp-deu", "DEU", "89.99", start: nil, end: today.adding(days: 30)),
            price("mp-future", "DEU", "79.99", start: today.adding(days: 30), end: nil),
        ])
        return catalog
    }

    @Test func scheduleReplaceCarriesTheWholeScheduleIncludingFutureManualPrices() throws {
        let draft = try plan(.iap(IAPPlanSpec(iapId: "life", baseTerritory: "USA",
                                              prices: [TerritoryAmount(territory: "USA", amount: d("89.99")), TerritoryAmount(territory: "CZE", amount: d("49.99"))],
                                              startDate: nil)), catalog().snapshot())
        #expect(draft.ops == [.scheduleReplace])
        guard case let .replaceIAPSchedule(schedule) = draft.items[0].payload else { Issue.record("payload"); return }
        #expect(schedule.baseTerritory == "USA")
        #expect(schedule.manualPrices.map { "\($0.territory) \($0.pricePointId.split(separator: "|").last!) \($0.startDate?.iso ?? "-") \($0.endDate?.iso ?? "-")" } == [
            "CZE 49.99 - -",
            "DEU 89.99 - \(today.adding(days: 30).iso)",
            "DEU 79.99 \(today.adding(days: 30).iso) -",
            "USA 89.99 - -",
        ])
        #expect(draft.verdicts("L2").map(\.severity) == [.warn])
    }

    @Test func scheduledChangeEndsTheCurrentManualPrice() throws {
        let start = today.adding(days: 10)
        let draft = try plan(.iap(IAPPlanSpec(iapId: "life", baseTerritory: "USA", prices: [TerritoryAmount(territory: "USA", amount: d("49.99"))],
                                              startDate: start)), catalog().snapshot())
        guard case let .replaceIAPSchedule(schedule) = draft.items.first?.payload else { Issue.record("payload"); return }
        let usa = schedule.manualPrices.filter { $0.territory == "USA" }
        #expect(usa.map(\.startDate) == [nil, start])
        #expect(usa.map(\.endDate) == [start, nil])
        #expect(draft.verdicts("L3").map(\.severity) == [.confirm(.c2)])
    }

    @Test func unchangedScheduleIsNoOpAndMissingBaseBlocks() throws {
        let same = try plan(.iap(IAPPlanSpec(iapId: "life", baseTerritory: "USA", prices: [TerritoryAmount(territory: "USA", amount: d("99.99"))], startDate: nil)),
                            catalog().snapshot())
        #expect(same.items.isEmpty)
        let noBase = try plan(.iap(IAPPlanSpec(iapId: "life", baseTerritory: "CZE", prices: [], startDate: nil)), catalog().snapshot())
        #expect(noBase.verdicts("L1").map(\.severity) == [.block(.plan)])
    }
}

@Suite struct WithdrawAndFixPlannerTests {
    func stored(_ item: PlannedItem, state: ItemState, ascId: String?) -> StoredItem {
        StoredItem(planId: "plan-1", item: item, state: state, attempts: 1, ascId: ascId, errorJSON: nil, verifiedAt: nil, effectiveAt: nil, supersededBy: nil)
    }

    @Test func withdrawDeletesDoneFutureRows() throws {
        var catalog = yearly()
        let start = today.adding(days: 10)
        catalog.setRegular("s", "USA", d("34.99"), start: start, ascId: "rp-written")
        catalog.addIntro("s", "DEU", price: d("25.99"), start: start, ascId: "io-written")
        let snapshot = catalog.snapshot()
        let regular = ItemFactory.regularPost(1, yearly().snapshot(), sub: "s", territory: "USA", price: d("34.99"), start: start, preserve: true)
        let intro = ItemFactory.introPost(2, before: .intro(current: nil, future: nil), sub: "s", territory: "DEU", price: d("25.99"), start: start)
        let pending = ItemFactory.regularPost(3, yearly().snapshot(), sub: "s", territory: "CZE", price: d("34.99"), start: start, preserve: true)
        let context = PlanningContext(snapshot: snapshot, config: SyntheticCatalog.config(), today: today,
                                      referencedItems: ["plan-1": [stored(regular, state: .done, ascId: "rp-written"),
                                                                   stored(intro, state: .done, ascId: "io-written"),
                                                                   stored(pending, state: .pending, ascId: nil)]])
        let draft = try Planner(policy: PolicyEngine()).plan(.withdraw(WithdrawPlanSpec(planId: "plan-1", itemSeqs: [1, 2, 3])), context: context)
        #expect(draft.items.map(\.payload) == [.deleteRegularPrice(ascId: "rp-written"), .deleteIntro(ascId: "io-written")])
        #expect(draft.verdicts.contains { $0.severity == .warn && $0.message.contains("Item 3 is not Done") })
        #expect(draft.spec.origin == .withdraw)
    }

    @Test func withdrawWithoutReferencedItemsBlocks() throws {
        let draft = try plan(.withdraw(WithdrawPlanSpec(planId: "missing", itemSeqs: [1])), yearly().snapshot())
        #expect(draft.items.isEmpty)
        #expect(draft.blocks.count == 1)
    }

    @Test func fixPlansTheUnderlyingSpecWithFixOrigin() throws {
        let spec = PlanSpec.fix(findingIds: [11, 12], underlying: introSpec(.percentOfRegular(d("0.8")), territories: ["USA"]))
        let draft = try plan(spec, yearly(.readyToSubmit).snapshot())
        #expect(draft.spec.origin == .fix)
        #expect(draft.ops == [.post])
        if case let .fix(ids, _) = draft.spec { #expect(ids == [11, 12]) } else { Issue.record("spec") }
    }
}

@Suite struct PromoOrderingTests {
    @Test func paygPromoRepriceComesBeforeRegularDecrease() throws {
        var catalog = yearly(.readyToSubmit)
        catalog.addPromo("s", code: "payg", prices: ["USA": d("19.99"), "DEU": d("19.99"), "CZE": d("19.99")])
        let mapping = ImportMapping(version: 1, source: .csv, firstDataRow: 2, countryColumn: "A", currencyColumn: "B", targets: [
            ImportTarget(column: "C", productAscId: "s", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: true),
            ImportTarget(column: "D", productAscId: "s", kind: .promoPrice(offerCode: "payg"), nominalDiscount: nil, writes: true),
        ])
        let table = ImportedTable(mappingVersion: 1, sha256: "x", rows: [
            ImportedRow(rowNumber: 2, territory: "USA", currency: "USD", values: ["C": .amount(d("18.99")), "D": .amount(d("14.99"))]),
        ], rawRows: [])
        let spec = PlanSpec.importTable(ImportPlanSpec(table: table, writeColumns: ["C", "D"], filter: PlanFilter(),
                                                       startDate: today.adding(days: 7), preserveCurrentPrice: nil, canary: false))
        let draft = try plan(spec, catalog.snapshot(), config: SyntheticCatalog.config(mapping: mapping))
        #expect(draft.ops == [.patchPrices, .post])
        #expect(draft.items[1].dependsOn == [1])
        #expect(draft.verdicts("O5").isEmpty)
    }
}
