import Foundation
import Domain
import Catalog

/// One cell of a synthetic plan: what to seed into FakeASC first and which payloads to chain on the cell.
public struct ScenarioCell: Sendable {
    public var seed: @Sendable (inout FakeModel) -> Void
    public var cell: CellKey
    public var payloads: [WritePayload]
    public init(seed: @escaping @Sendable (inout FakeModel) -> Void = { _ in }, cell: CellKey, payloads: [WritePayload]) {
        self.seed = seed; self.cell = cell; self.payloads = payloads
    }
}

public enum Scenarios {
    static func day(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

    /// Scheduled change on 2026-11-20 replaced by DELETE -> POST (R5 pair).
    public static func replaceScheduledRegular(sub: String = "sub-y", territory: TerritoryCode) -> ScenarioCell {
        let scheduledId = "price-sched-\(sub)-\(territory)"
        return ScenarioCell(seed: { model in
            model.regularPrices.append(FakeRegularPrice(id: scheduledId, subscriptionId: sub, territory: territory, planType: .upfront,
                                                        sendsPlanType: true, startDate: day("2026-11-20"), preserved: false,
                                                        pricePointId: "pp-\(sub)-\(territory)-11"))
        }, cell: .regular(subscriptionId: sub, territory: territory, planType: .upfront), payloads: [
            .deleteRegularPrice(ascId: scheduledId),
            .createRegularPrice(NewRegularPrice(subscriptionId: sub, territory: territory, planType: .upfront,
                                                pricePointId: "pp-\(sub)-\(territory)-12", startDate: day("2026-11-20"), preserveCurrentPrice: true)),
        ])
    }

    /// Live intro ended on D = 2026-11-01 and a new one created from D (I7 order PATCH_END -> POST).
    public static func endLiveIntroThenPost(sub: String = "sub-y", territory: TerritoryCode) -> ScenarioCell {
        let liveId = "intro-live-\(sub)-\(territory)"
        return ScenarioCell(seed: { model in
            model.intros.append(FakeIntro(id: liveId, subscriptionId: sub, territory: territory, planType: .upfront, mode: .freeTrial,
                                          duration: .oneWeek, numberOfPeriods: 1, startDate: day("2026-01-01"), endDate: nil,
                                          pricePointId: nil, createdOn: day("2026-01-01")))
        }, cell: .intro(subscriptionId: sub, territory: territory, planType: .upfront), payloads: [
            .endIntro(ascId: liveId, endDate: day("2026-11-01")),
            .createIntro(NewIntroOffer(subscriptionId: sub, territory: territory, planType: .upfront, mode: .freeTrial, duration: .oneMonth,
                                       numberOfPeriods: 1, startDate: day("2026-11-01"), endDate: nil, pricePointId: nil)),
        ])
    }

    /// Future intro (2026-12-01) replaced by DELETE -> POST.
    public static func replaceFutureIntro(sub: String = "sub-y", territory: TerritoryCode) -> ScenarioCell {
        let futureId = "intro-future-\(sub)-\(territory)"
        return ScenarioCell(seed: { model in
            model.intros.append(FakeIntro(id: futureId, subscriptionId: sub, territory: territory, planType: .upfront, mode: .freeTrial,
                                          duration: .oneWeek, numberOfPeriods: 1, startDate: day("2026-12-01"), endDate: nil,
                                          pricePointId: nil, createdOn: day("2026-10-01")))
        }, cell: .intro(subscriptionId: sub, territory: territory, planType: .upfront), payloads: [
            .deleteIntro(ascId: futureId),
            .createIntro(NewIntroOffer(subscriptionId: sub, territory: territory, planType: .upfront, mode: .freeTrial, duration: .twoWeeks,
                                       numberOfPeriods: 1, startDate: day("2026-12-01"), endDate: nil, pricePointId: nil)),
        ])
    }

    public static func newRegularPrice(sub: String, territory: TerritoryCode, pointIndex: Int, start: String) -> ScenarioCell {
        ScenarioCell(cell: .regular(subscriptionId: sub, territory: territory, planType: .upfront), payloads: [
            .createRegularPrice(NewRegularPrice(subscriptionId: sub, territory: territory, planType: .upfront,
                                                pricePointId: "pp-\(sub)-\(territory)-\(pointIndex)", startDate: day(start), preserveCurrentPrice: true)),
        ])
    }

    public static func newIntro(sub: String, territory: TerritoryCode, start: String) -> ScenarioCell {
        ScenarioCell(cell: .intro(subscriptionId: sub, territory: territory, planType: .upfront), payloads: [
            .createIntro(NewIntroOffer(subscriptionId: sub, territory: territory, planType: .upfront, mode: .freeTrial, duration: .oneWeek,
                                       numberOfPeriods: 1, startDate: day(start), endDate: nil, pricePointId: nil)),
        ])
    }

    public static func createPromo(sub: String, code: String, territories: [TerritoryCode]) -> ScenarioCell {
        ScenarioCell(cell: .promo(subscriptionId: sub, offerCode: code), payloads: [
            .createPromo(NewPromoOffer(subscriptionId: sub, offerCode: code, name: code, mode: .payAsYouGo, duration: .oneMonth,
                                       numberOfPeriods: 3, planType: .upfront,
                                       prices: territories.map { NewPromoPrice(territory: $0, pricePointId: "pp-\(sub)-\($0)-1") })),
        ])
    }

    /// Existing promo (prices at point index 3) re-priced to index 2 with the full price set (O6).
    public static func repricePromo(sub: String, code: String, territories: [TerritoryCode]) -> ScenarioCell {
        let promoId = "promo-seed-\(code)"
        return ScenarioCell(seed: { model in
            model.promos.append(FakePromo(id: promoId, subscriptionId: sub, offerCode: code, name: code, mode: .payAsYouGo,
                                          duration: .oneMonth, numberOfPeriods: 3, planType: .upfront,
                                          prices: territories.sorted().map {
                                              FakePromoPrice(id: "promoprice-seed-\(code)-\($0)", territory: $0, pricePointId: "pp-\(sub)-\($0)-3")
                                          }))
            model.usedOfferCodes.insert(code)
        }, cell: .promo(subscriptionId: sub, offerCode: code), payloads: [
            .replacePromoPrices(ascId: promoId, prices: territories.map { NewPromoPrice(territory: $0, pricePointId: "pp-\(sub)-\($0)-2") }),
        ])
    }

    public static func replaceIAPSchedule() -> ScenarioCell {
        ScenarioCell(cell: .iapSchedule(iapId: "iap-life"), payloads: [
            .replaceIAPSchedule(NewIAPSchedule(iapId: "iap-life", baseTerritory: "USA", manualPrices: [
                NewIAPManualPrice(territory: "USA", pricePointId: "pp-iap-life-USA-29", startDate: nil, endDate: nil),
                NewIAPManualPrice(territory: "CZE", pricePointId: "pp-iap-life-CZE-25", startDate: day("2026-11-10"), endDate: nil),
            ])),
        ])
    }

    /// 12 items over 9 cells, three of them chained (DELETE -> POST, PATCH_END -> POST, DELETE -> POST intro).
    public static var twelveItems: [ScenarioCell] {
        [replaceScheduledRegular(territory: "CZE"), endLiveIntroThenPost(territory: "DEU"), replaceFutureIntro(territory: "FRA"),
         newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15"),
         newIntro(sub: "sub-m", territory: "USA", start: "2026-11-01"),
         createPromo(sub: "sub-m", code: "spring_v1", territories: ["USA", "CZE"]),
         repricePromo(sub: "sub-y", code: "winter_v1", territories: ["USA", "CZE"]),
         replaceIAPSchedule(),
         newRegularPrice(sub: "sub-m", territory: "JPN", pointIndex: 5, start: "2026-11-15")]
    }

    /// Seeds every cell, syncs, chains items with consecutive seqs and stores the plan.
    public static func plan(_ h: ExecutorHarness, cells: [ScenarioCell], state: PlanState = .draft,
                            excluded: [CellKey] = []) async throws -> (planId: String, items: [PlannedItem]) {
        for cell in cells { await h.fake.mutate(cell.seed) }
        let snapshot = try await h.initialSync()
        var items: [PlannedItem] = []
        var seq = 1
        for cell in cells {
            items += ItemFactory.chain(cell: cell.cell, payloads: cell.payloads, firstSeq: seq, snapshot: snapshot, today: h.today)
            seq += cell.payloads.count
        }
        return (try h.insertPlan(items: items, state: state, excluded: excluded), items)
    }
}
