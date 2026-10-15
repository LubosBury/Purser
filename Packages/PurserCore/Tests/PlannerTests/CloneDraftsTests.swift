import Foundation
import Testing
import Domain
import Catalog
import Policy
@testable import Planner
import PurserTestSupport

/// Source "s" (yearly, 29.99 / 24.99 / 19.99 with a trial, a paid future intro and a PAYG promo) and its clone "c" without
/// prices; source IAP "life" and its clone "lc" without a schedule. Every product has the synthetic ladder 0.99 … 99.99.
private func cloneCatalog() -> SyntheticCatalog {
    var catalog = SyntheticCatalog()
    catalog.addSubscription("s", prices: ["USA": d("29.99"), "DEU": d("24.99"), "CZE": d("19.99")])
    catalog.addSubscription("c", prices: [:], state: .missingMetadata, available: ["USA", "DEU", "CZE"])
    let soon = today.adding(days: 30)
    catalog.addIntro("s", "USA", mode: .freeTrial, duration: .oneWeek, price: nil, end: soon)
    catalog.addIntro("s", "DEU", mode: .freeTrial, duration: .oneWeek, price: nil)
    catalog.addIntro("s", "CZE", mode: .freeTrial, duration: .twoWeeks, price: nil)
    catalog.addIntro("s", "USA", mode: .payUpFront, duration: .oneMonth, price: d("9.99"), start: soon, end: today.adding(days: 60))
    catalog.addPromo("s", code: "winback", mode: .payAsYouGo, duration: .oneYear, periods: 1,
                     prices: ["USA": d("14.99"), "DEU": d("12.99"), "CZE": d("9.99")])
    catalog.addIAP("life", base: "USA", manual: ["USA": d("49.99"), "DEU": d("44.99")])
    catalog.iaps["lc"] = IAPInfo(ascId: "lc", productId: "com.example.lc", name: "Synthetic lc", iapType: "NON_CONSUMABLE", state: .missingMetadata)
    catalog.addLadder(product: "lc", territories: ["USA", "DEU"], planType: nil)
    return catalog
}

private let created = ["s": "c", "life": "lc"]

private func drafts(_ catalog: SyntheticCatalog, copy: CloneCopy = CloneCopy()) -> [(title: String, spec: PlanSpec)] {
    CloneDrafts.specs(created: created, copy: copy, offerCodeSuffix: "_AB3", snapshot: catalog.snapshot(), today: today)
}

private func isIntro(_ spec: PlanSpec) -> Bool { if case .intro = spec { return true } else { return false } }
private func isPromo(_ spec: PlanSpec) -> Bool { if case .promo = spec { return true } else { return false } }
private func isIAP(_ spec: PlanSpec) -> Bool { if case .iap = spec { return true } else { return false } }

@Suite struct CloneDraftsTests {
    @Test func draftsComeInTheOrderTheyMustBeApplied() {
        #expect(drafts(cloneCatalog()).map(\.title) == [
            "Clone com.example.c of com.example.s: regular prices (apply first)",
            "Clone com.example.c of com.example.s: intro FREE_TRIAL of several lengths, at once",
            "Clone com.example.c of com.example.s: intro FREE_TRIAL ONE_WEEK, at once until 2026-11-08",
            "Clone com.example.c of com.example.s: intro PAY_UP_FRONT ONE_MONTH, from 2026-11-08 until 2026-12-08",
            "Clone com.example.c of com.example.s: promotional offer winback_AB3",
            "Clone com.example.lc of com.example.life: prices",
        ])
    }

    @Test func regularPricesSnapToTheClonePointOfTheSamePrice() throws {
        let catalog = cloneCatalog()
        let draft = try plan(try #require(drafts(catalog).first).spec, catalog.snapshot())
        #expect(draft.blocks.isEmpty)
        let prices = draft.items.compactMap { item -> NewRegularPrice? in
            if case let .createRegularPrice(price) = item.payload { return price } else { return nil }
        }
        #expect(Dictionary(uniqueKeysWithValues: prices.map { ($0.territory, $0.pricePointId) }) == [
            "USA": SyntheticCatalog.pointId("c", "USA", .upfront, d("29.99")),
            "DEU": SyntheticCatalog.pointId("c", "DEU", .upfront, d("24.99")),
            "CZE": SyntheticCatalog.pointId("c", "CZE", .upfront, d("19.99")),
        ])
        #expect(prices.allSatisfy { $0.subscriptionId == "c" && $0.startDate == nil && $0.planType == .upfront })
    }

    @Test func introOffersAreGroupedByShapeAndKeepTheirTier() throws {
        let catalog = cloneCatalog()
        let intros = drafts(catalog).filter { isIntro($0.spec) }
        #expect(intros.count == 3)
        guard intros.count == 3, case let .intro(lengths) = intros[0].spec, case let .intro(trial) = intros[1].spec,
              case let .intro(paid) = intros[2].spec else { Issue.record("not three intro specs"); return }
        #expect(lengths.pricing == .trialLengths(["DEU": .oneWeek, "CZE": .twoWeeks]))
        #expect(lengths.duration == .oneWeek)     // one territory each: the tie goes to the shorter length
        #expect(lengths.filter.territories == ["DEU", "CZE"] && lengths.startDate == nil && lengths.endDate == nil)
        #expect(trial.pricing == .freeTrial && trial.duration == .oneWeek && trial.filter.territories == ["USA"])
        #expect(trial.startDate == nil && trial.endDate == today.adding(days: 30))
        #expect(paid.mode == .payUpFront && paid.duration == .oneMonth)
        #expect(paid.pricing == .table([TerritoryAmount(territory: "USA", amount: d("9.99"))]))
        #expect(paid.startDate == today.adding(days: 30) && paid.endDate == today.adding(days: 60))

        let first = try plan(intros[0].spec, catalog.snapshot())
        #expect(first.blocks.isEmpty)
        #expect(Dictionary(uniqueKeysWithValues: first.offers.map { ($0.territory, $0.duration) }) == ["DEU": .oneWeek, "CZE": .twoWeeks])
        #expect(first.offers.allSatisfy { $0.startDate == nil && $0.pricePointId == nil && $0.mode == .freeTrial })
        let last = try plan(intros[2].spec, catalog.snapshot())
        #expect(last.blocks.isEmpty)
        #expect(last.offers.map(\.pricePointId) == [SyntheticCatalog.pointId("c", "USA", .upfront, d("9.99"))])
        #expect(last.offers.first?.startDate == today.adding(days: 30))
    }

    @Test func promotionalOffersGetTheSuffixAndTheSourceTier() throws {
        let catalog = cloneCatalog()
        let promo = try #require(drafts(catalog).first { isPromo($0.spec) })
        guard case let .promo(spec) = promo.spec,
              case let .create(subscriptionId, code, name, mode, duration, periods, _) = spec.action else {
            Issue.record("not a promo create")
            return
        }
        #expect(subscriptionId == "c" && code == "winback_AB3" && name == "Promo winback_AB3")
        #expect(mode == .payAsYouGo && duration == .oneYear && periods == 1)
        #expect(OfferCodeAdvisor(registry: catalog.snapshot().offerCodesEverSeen).check(code).isAcceptable)
        let draft = try plan(promo.spec, catalog.snapshot())
        #expect(draft.blocks.isEmpty)
        let offer = try #require(draft.items.compactMap { item -> NewPromoOffer? in
            if case let .createPromo(offer) = item.payload { return offer } else { return nil }
        }.first)
        #expect(Dictionary(uniqueKeysWithValues: offer.prices.map { ($0.territory, $0.pricePointId) }) == [
            "USA": SyntheticCatalog.pointId("c", "USA", .upfront, d("14.99")),
            "DEU": SyntheticCatalog.pointId("c", "DEU", .upfront, d("12.99")),
            "CZE": SyntheticCatalog.pointId("c", "CZE", .upfront, d("9.99")),
        ])
    }

    @Test func inAppPurchasePricesKeepTheBaseTerritoryAndTheTier() throws {
        let catalog = cloneCatalog()
        let iap = try #require(drafts(catalog).last)
        #expect(iap.spec == .iap(IAPPlanSpec(iapId: "lc", baseTerritory: "USA",
                                             prices: [TerritoryAmount(territory: "DEU", amount: d("44.99")),
                                                      TerritoryAmount(territory: "USA", amount: d("49.99"))],
                                             startDate: nil)))
        let draft = try plan(iap.spec, catalog.snapshot())
        #expect(draft.blocks.isEmpty)
        guard case let .replaceIAPSchedule(schedule)? = draft.items.first?.payload else { Issue.record("no schedule"); return }
        #expect(schedule.baseTerritory == "USA")
        #expect(Set(schedule.manualPrices.map(\.pricePointId)) == [SyntheticCatalog.pointId("lc", "USA", nil, d("49.99")),
                                                                   SyntheticCatalog.pointId("lc", "DEU", nil, d("44.99"))])
    }

    @Test func whatTheCloneAlreadyHasIsLeftOut() {
        var catalog = cloneCatalog()
        catalog.setRegular("c", "USA", d("29.99"))
        catalog.addIntro("c", "DEU", mode: .freeTrial, duration: .oneWeek, price: nil)
        catalog.addPromo("c", code: "winback_AB3", mode: .payAsYouGo, duration: .oneYear, periods: 1, prices: ["USA": d("14.99")])
        catalog.iapSchedules["lc"] = IAPSchedule(iapId: "lc", scheduleId: "sched-lc", baseTerritory: "USA", manualPrices: [])
        let all = drafts(catalog)
        guard case let .regular(regular)? = all.first?.spec else { Issue.record("no regular spec"); return }
        #expect(Set(regular.prices.map(\.territory)) == ["DEU", "CZE"])
        guard all.count > 1, case let .intro(rest) = all[1].spec else { Issue.record("no intro spec"); return }
        #expect(rest.pricing == .freeTrial && rest.duration == .twoWeeks && rest.filter.territories == ["CZE"])
        #expect(!all.contains { isPromo($0.spec) })
        #expect(!all.contains { isIAP($0.spec) })
    }

    @Test func theCopyChoiceAndTheNotesSayWhatIsLeftOut() {
        var catalog = cloneCatalog()
        catalog.setRegular("s", "USA", d("34.99"), start: today.adding(days: 10), ascId: "rp-s-next")
        catalog.iapSchedules["life"]?.manualPrices.append(IAPManualPrice(
            ascId: "mp-next", territory: "USA", pricePointId: SyntheticCatalog.pointId("life", "USA", nil, d("54.99")),
            startDate: today.adding(days: 20), endDate: nil, customerPrice: d("54.99")))
        catalog.addSubscription("m", prices: ["USA": d("9.99")], monthly: true)
        catalog.setRegular("m", "USA", d("0.99"), planType: .monthly)
        let snapshot = catalog.snapshot()
        #expect(CloneDrafts.specs(created: created, copy: CloneCopy(prices: false, introOffers: false, promoOffers: false),
                                  offerCodeSuffix: "_AB3", snapshot: snapshot, today: today).isEmpty)
        let notes = CloneDrafts.notCopied(created: created, copy: CloneCopy(), offerCodeSuffix: "_AB3", snapshot: snapshot, today: today)
        #expect(notes.contains { $0.contains("scheduled price changes of com.example.s") && $0.contains(today.adding(days: 10).iso) })
        #expect(notes.contains { $0.contains("future prices of com.example.life") && $0.contains(today.adding(days: 20).iso) })
        #expect(CloneDrafts.notCopied(created: ["m": "c"], copy: CloneCopy(), offerCodeSuffix: "_AB3", snapshot: snapshot, today: today)
                    .contains { $0.contains("MONTHLY prices of com.example.m") })
        #expect(CloneDrafts.notCopied(created: ["s": "missing"], copy: CloneCopy(), offerCodeSuffix: "_AB3", snapshot: snapshot, today: today)
                == ["The clone of com.example.s is not in the catalog yet; sync and prepare the drafts again."])
    }

    // MARK: Review fixes: what a draft cannot carry is said, not dropped

    private func notes(_ catalog: SyntheticCatalog, created: [String: String] = ["s": "c"], copy: CloneCopy = CloneCopy()) -> [String] {
        CloneDrafts.notCopied(created: created, copy: copy, offerCodeSuffix: "_AB3", snapshot: catalog.snapshot(), today: today)
    }

    private func specs(_ catalog: SyntheticCatalog, created: [String: String] = ["s": "c"], copy: CloneCopy = CloneCopy()) -> [(title: String, spec: PlanSpec)] {
        CloneDrafts.specs(created: created, copy: copy, offerCodeSuffix: "_AB3", snapshot: catalog.snapshot(), today: today)
    }

    @Test func aPromoCodeTooLongForTheSuffixIsNotDraftedAndSaid() {
        var catalog = cloneCatalog()
        let long = String(repeating: "x", count: 62)        // 62 + "_AB3" = 66 > OfferCodeAdvisor.maxLength
        catalog.addPromo("s", code: long, mode: .payAsYouGo, duration: .oneYear, periods: 1, prices: ["USA": d("14.99")])
        #expect(OfferCodeAdvisor(registry: []).check(long + "_AB3").problems.contains(.tooLong(66)))
        let promos = specs(catalog).filter { isPromo($0.spec) }
        #expect(promos.map(\.title) == ["Clone com.example.c of com.example.s: promotional offer winback_AB3"])
        #expect(notes(catalog).contains("Promotional offer Promo \(long) of com.example.s not copied: the code \(long)_AB3 would be too long or invalid."))
        #expect(CloneDrafts.isUsableOfferCode("winback_AB3") && !CloneDrafts.isUsableOfferCode(long + "_AB3"))
        #expect(!CloneDrafts.isUsableOfferCode("bad code_AB3"))
    }

    @Test func aPromoCodeUsedBeforeIsNotDraftedAndSaid() {
        var catalog = cloneCatalog()
        catalog.offerCodes.insert("winback_AB3")             // seen once, e.g. on an offer that was deleted since
        #expect(!specs(catalog).contains { isPromo($0.spec) })
        #expect(notes(catalog).contains("Promotional offer Promo winback of com.example.s not copied: the code winback_AB3 was already used in this workspace and cannot be used again."))
    }

    @Test func territoriesTheCloneIsNotAvailableInAreSaid() {
        var catalog = cloneCatalog()
        catalog.subscriptions["c"]?.availableTerritories = ["USA", "DEU"]
        guard case let .regular(regular)? = specs(catalog).first?.spec else { Issue.record("no regular spec"); return }
        #expect(Set(regular.prices.map(\.territory)) == ["USA", "DEU"])
        #expect(notes(catalog).contains("1 territory where com.example.s has a price is not available for the clone; its price there is not copied."))
        catalog.subscriptions["c"]?.availableTerritories = ["USA"]
        #expect(notes(catalog).contains("2 territories where com.example.s has a price are not available for the clone; their prices are not copied."))
        #expect(notes(catalog, copy: CloneCopy(prices: false)).allSatisfy { !$0.contains("territor") })
    }

    @Test func aCloneWithNoTerritoryInCommonGetsNoDraftsAndTheReasonIsSaid() {
        var catalog = cloneCatalog()
        catalog.subscriptions["c"]?.availableTerritories = ["FRA"]
        #expect(specs(catalog).filter { $0.title.hasPrefix("Clone com.example.c ") }.isEmpty)
        let said = notes(catalog)
        #expect(said.contains { $0.hasPrefix("No territory is available for both com.example.s and its clone") })
        #expect(!said.contains { $0.contains("territories where") })
        #expect(notes(catalog, copy: CloneCopy(prices: false, introOffers: false, promoOffers: false)).isEmpty)
    }

    @Test func aPaidOfferWithoutAPriceIsNotDraftedWithAnEmptyTable() {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": d("29.99")])
        catalog.addSubscription("c", prices: [:], state: .missingMetadata, available: ["USA"])
        catalog.addIntro("s", "USA", mode: .payUpFront, duration: .oneMonth, price: nil)
        catalog.addPromo("s", code: "free-ish", mode: .payUpFront, duration: .oneMonth, periods: 1, prices: ["USA": nil])
        let all = specs(catalog)
        #expect(all.map(\.title) == ["Clone com.example.c of com.example.s: regular prices (apply first)"])
        let said = notes(catalog)
        #expect(said.contains("The introductory offer PAY_UP_FRONT ONE_MONTH, at once of com.example.s is not copied: the catalog has no price for it."))
        #expect(said.contains("Promotional offer Promo free-ish of com.example.s not copied: it has no price in a territory where the clone is available."))
    }

    /// Two sources with the same promotional offer code would give their clones the same suffixed code, and a code can be
    /// used only once: the source with the lower asc id keeps it, the other offer is left out and said.
    @Test func twoSourcesWithTheSamePromoCodeGiveItToTheFirstCloneOnly() {
        var catalog = cloneCatalog()
        catalog.addSubscription("s2", prices: ["USA": d("19.99")])
        catalog.addSubscription("c2", prices: [:], state: .missingMetadata, available: ["USA"])
        catalog.addPromo("s2", code: "winback", mode: .payAsYouGo, duration: .oneYear, periods: 1, prices: ["USA": d("9.99")], ascId: "po-winback-s2")
        let both = ["s": "c", "s2": "c2"]
        let promos = specs(catalog, created: both).filter { isPromo($0.spec) }
        #expect(promos.map(\.title) == ["Clone com.example.c of com.example.s: promotional offer winback_AB3"])
        #expect(notes(catalog, created: both).contains("Promotional offer Promo winback of com.example.s2 not copied: the code winback_AB3 goes to the clone of com.example.s; a code can be used only once."))
        // The order of the dictionary does not decide: the lower asc id wins whichever way the pairs are listed.
        let reversed = specs(catalog, created: ["s2": "c2", "s": "c"]).filter { isPromo($0.spec) }
        #expect(reversed.map(\.title) == promos.map(\.title))
    }
}
