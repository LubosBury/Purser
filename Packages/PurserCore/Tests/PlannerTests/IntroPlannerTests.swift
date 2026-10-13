import Foundation
import Testing
import Domain
import Catalog
import Importer
import Policy
@testable import Planner
import PurserTestSupport

func introSpec(_ pricing: IntroPricing, mode: OfferMode = .payUpFront, duration: OfferDuration = .oneYear, periods: Int = 1,
               start: CalendarDate? = nil, end: CalendarDate? = nil, nominal: Decimal? = nil,
               territories: Set<TerritoryCode>? = nil, canary: Bool = false) -> PlanSpec {
    .intro(IntroPlanSpec(subscriptionIds: ["s"], mode: mode, duration: duration, numberOfPeriods: periods, pricing: pricing,
                         startDate: start, endDate: end, nominalDiscount: nominal,
                         filter: PlanFilter(territories: territories), canary: canary))
}

extension PlanDraft {
    var offers: [NewIntroOffer] { items.compactMap { if case let .createIntro(o) = $0.payload { return o } else { return nil } } }
}

@Suite struct IntroPlannerTests {
    @Test func freeTrialOnUnsubmittedProductStartsImmediately() throws {
        let draft = try plan(introSpec(.freeTrial, mode: .freeTrial, duration: .oneWeek), yearly(.readyToSubmit).snapshot())
        #expect(draft.ops == [.post, .post, .post])
        #expect(draft.offers.allSatisfy { $0.startDate == nil && $0.pricePointId == nil && $0.mode == .freeTrial && $0.numberOfPeriods == 1 })
        #expect(draft.blocks.isEmpty)
    }

    @Test func approvedProductDefaultsToLeadTime() throws {
        let draft = try plan(introSpec(.freeTrial, mode: .freeTrial, duration: .oneWeek), yearly(.approved).snapshot())
        #expect(draft.offers.allSatisfy { $0.startDate == today.adding(days: AppleConstants.minLeadDays) })
        #expect(draft.verdicts("R4").isEmpty)
    }

    @Test func percentOfRegularSnapsDown() throws {
        let draft = try plan(introSpec(.percentOfRegular(d("0.8")), territories: ["USA"]), yearly(.readyToSubmit).snapshot())
        // 0.8 x 29.99 = 23.992 -> 23.99
        #expect(draft.offers.map(\.pricePointId) == [SyntheticCatalog.pointId("s", "USA", .upfront, d("23.99"))])
        #expect(draft.items[0].flags.isEmpty)
    }

    @Test func percentUsesLowestRegularPriceDuringTheIntro() throws {
        var catalog = yearly(.readyToSubmit)
        catalog.setRegular("s", "USA", d("24.99"), start: today.adding(days: 10), ascId: "rp-cut")
        let draft = try plan(introSpec(.percentOfRegular(d("0.8")), territories: ["USA"]), catalog.snapshot())
        // 0.8 x 24.99 = 19.992 -> 19.99
        #expect(draft.offers.first?.pricePointId == SyntheticCatalog.pointId("s", "USA", .upfront, d("19.99")))
        let short = try plan(introSpec(.percentOfRegular(d("0.8")), end: today.adding(days: 10), territories: ["USA"]), catalog.snapshot())
        #expect(short.offers.first?.pricePointId == SyntheticCatalog.pointId("s", "USA", .upfront, d("23.99")))
    }

    @Test func tablePricingIsCappedByNominalDiscount() throws {
        let draft = try plan(introSpec(.table([TerritoryAmount(territory: "USA", amount: d("25.99")), TerritoryAmount(territory: "DEU", amount: d("19.99"))]),
                                       nominal: d("0.2")), yearly(.readyToSubmit).snapshot())
        #expect(draft.offers.map(\.territory) == ["DEU", "USA"])
        #expect(draft.offers[1].pricePointId == SyntheticCatalog.pointId("s", "USA", .upfront, d("23.99")))
        #expect(draft.items[1].flags == [.limitedByI5])
        #expect(draft.items[0].flags.isEmpty)
        #expect(draft.verdicts("I5").map(\.severity) == [.warn])
    }

    @Test func trialLengthsPerTerritory() throws {
        let draft = try plan(introSpec(.trialLengths(["USA": .oneMonth, "DEU": .twoWeeks]), mode: .freeTrial, duration: .oneWeek),
                             yearly(.readyToSubmit).snapshot())
        #expect(draft.offers.map(\.duration) == [.oneWeek, .twoWeeks, .oneMonth])
        #expect(draft.offers.map(\.territory) == ["CZE", "DEU", "USA"])
    }

    @Test func payAsYouGoKeepsNumberOfPeriods() throws {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": d("9.99")], period: .oneMonth, state: .readyToSubmit)
        let draft = try plan(introSpec(.percentOfRegular(d("0.5")), mode: .payAsYouGo, duration: .oneMonth, periods: 3), catalog.snapshot())
        #expect(draft.offers.map(\.numberOfPeriods) == [3])
        // 0.5 x 9.99 = 4.995 -> 4.99
        #expect(draft.offers.first?.pricePointId == SyntheticCatalog.pointId("s", "USA", .upfront, d("4.99")))
        #expect(draft.verdicts("I2").isEmpty)
    }

    @Test func liveIntroOnApprovedProductIsEndedAtDAndReplacedFromD() throws {
        var catalog = yearly(.approved)
        catalog.addIntro("s", "USA", price: d("25.99"))
        let draft = try plan(introSpec(.percentOfRegular(d("0.8")), territories: ["USA"]), catalog.snapshot())
        let day = today.adding(days: AppleConstants.minLeadDays)
        #expect(draft.ops == [.patchEnd, .post])
        #expect(draft.items[0].payload == .endIntro(ascId: "io-s-USA-2026-01-01", endDate: day))
        #expect(draft.offers.first?.startDate == day)
        #expect(draft.items[1].dependsOn == [1])
        #expect(draft.items[1].before == draft.items[0].target)
        #expect(draft.verdicts("I7").map(\.severity) == [.block(.plan)])
    }

    @Test func canaryKeepsFirstTerritoryAndNeedsC2() throws {
        var catalog = yearly(.approved)
        for t in ["USA", "DEU", "CZE"] as [TerritoryCode] { catalog.addIntro("s", t, price: d("25.99")) }
        let draft = try plan(introSpec(.percentOfRegular(d("0.8")), canary: true), catalog.snapshot())
        #expect(Set(draft.items.compactMap(\.cell.territory)) == ["CZE"])
        #expect(draft.blocks.isEmpty)
        #expect(draft.verdicts("I7").map(\.severity) == [.confirm(.c2)])
        #expect(draft.confirmationLevel == .c2)
    }

    @Test func effectiveCanaryUnlocksLiveIntroReplacementOfItsProduct() throws {
        var catalog = yearly(.approved)
        for t in ["USA", "DEU"] as [TerritoryCode] { catalog.addIntro("s", t, price: d("25.99")) }
        let spec = introSpec(.percentOfRegular(d("0.8")), territories: ["USA", "DEU"])
        let locked = try plan(spec, catalog.snapshot())
        #expect(locked.verdicts("I7").map(\.severity) == [.block(.plan)])
        let context = PlanningContext(snapshot: catalog.snapshot(), config: SyntheticCatalog.config(), today: today,
                                      effectiveLiveIntroCanaryProducts: ["s"])
        let unlocked = try Planner(policy: PolicyEngine()).plan(spec, context: context)
        #expect(unlocked.ops == [.patchEnd, .post, .patchEnd, .post])
        #expect(unlocked.verdicts("I7").isEmpty)
    }

    @Test func futureIntroIsDeletedThenPosted() throws {
        var catalog = yearly(.approved)
        catalog.addIntro("s", "USA", price: d("25.99"), start: today.adding(days: 20), ascId: "io-future")
        let draft = try plan(introSpec(.percentOfRegular(d("0.8")), start: today.adding(days: 20), territories: ["USA"]), catalog.snapshot())
        #expect(draft.ops == [.delete, .post])
        #expect(draft.items[0].payload == .deleteIntro(ascId: "io-future"))
        #expect(draft.blocks.isEmpty)
    }

    @Test func currentIntroOnUnsubmittedProductIsDeletedThenPosted() throws {
        var catalog = yearly(.readyToSubmit)
        catalog.addIntro("s", "USA", price: d("25.99"))
        let draft = try plan(introSpec(.percentOfRegular(d("0.8")), territories: ["USA"]), catalog.snapshot())
        #expect(draft.ops == [.delete, .post])
        #expect(draft.blocks.isEmpty)
    }

    @Test func identicalIntroIsNoOp() throws {
        var catalog = yearly(.approved)
        catalog.addIntro("s", "USA", price: d("23.99"))
        let draft = try plan(introSpec(.percentOfRegular(d("0.8")), territories: ["USA"]), catalog.snapshot())
        #expect(draft.items.isEmpty)
    }

    @Test func syntheticImportOf3ProductsBy175TerritoriesGives525Posts() async throws {
        let (table, importVerdicts) = try await SyntheticImport.importedTable()
        #expect(importVerdicts.isEmpty)
        let snapshot = SyntheticCatalog.fromSyntheticTable(table).snapshot()
        let spec = PlanSpec.importTable(ImportPlanSpec(table: table, writeColumns: ["D", "F", "H"], filter: PlanFilter(),
                                                       startDate: today.adding(days: 7), preserveCurrentPrice: nil, canary: false))
        let draft = try plan(spec, snapshot, config: SyntheticCatalog.config(mapping: SyntheticImport.mapping()))
        #expect(draft.items.count == 525)
        #expect(draft.items.allSatisfy { $0.op == .post })
        #expect(draft.blocks.isEmpty, "\(draft.blocks.prefix(3).map(\.message))")
        #expect(draft.excluded.isEmpty)
        #expect(draft.checkDiffs.isEmpty)
        #expect(Set(draft.offers.map(\.subscriptionId)) == [SyntheticImport.alpha, SyntheticImport.beta, SyntheticImport.gamma])
        #expect(draft.offers.allSatisfy { $0.mode == .payUpFront && $0.duration == .oneYear && $0.numberOfPeriods == 1 && $0.startDate == today.adding(days: 7) })
        #expect(draft.items.allSatisfy { $0.flags.isEmpty })
        #expect(draft.confirmationLevel == .c0)
    }
}
