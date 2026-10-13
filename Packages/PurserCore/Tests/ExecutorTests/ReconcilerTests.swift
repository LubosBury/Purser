import Foundation
import Testing
import Domain
import Catalog
@testable import Executor

private let today = CalendarDate(iso: "2026-10-09")!
private func d(_ s: String) -> CalendarDate { CalendarDate(iso: s)! }
private let p999 = Decimal(string: "9.99")!

private func price(_ id: String, start: String?, pp: String = "pp-sub-y-CZE-9", preserved: Bool = false) -> RegularPriceRow {
    RegularPriceRow(ascId: id, subscriptionId: "sub-y", territory: "CZE", planType: .upfront, rawPlanType: "UPFRONT",
                    startDate: start.map(d), preserved: preserved, pricePointId: pp, customerPrice: p999)
}

private func intro(_ id: String, start: String?, end: String? = nil, pp: String? = nil) -> IntroOfferRow {
    IntroOfferRow(ascId: id, subscriptionId: "sub-y", territory: "DEU", planType: .upfront, rawPlanType: "UPFRONT",
                  mode: pp == nil ? .freeTrial : .payUpFront, duration: pp == nil ? .oneWeek : .threeMonths, numberOfPeriods: 1,
                  startDate: start.map(d), endDate: end.map(d), pricePointId: pp, customerPrice: nil)
}

private func offer(_ id: String, code: String = "spring_v1", prices: [(TerritoryCode, String)]) -> PromoOffer {
    PromoOffer(ascId: id, subscriptionId: "sub-y", offerCode: code, name: code, mode: .payAsYouGo, duration: .oneYear,
               numberOfPeriods: 1, planType: .upfront,
               prices: prices.map { PromoPrice(ascId: "pp-row-\($0.0)", territory: $0.0, pricePointId: $0.1, customerPrice: nil) })
}

@Suite("Reconciler")
struct ReconcilerTests {
    @Test func beforeComparisonIsExact() {
        let live = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: price("price-2", start: "2026-11-01"))
        #expect(Reconciler.matches(live: live, expected: live, today: today))
        var changed = price("price-2", start: "2026-11-01")
        changed.customerPrice = Decimal(string: "10.99")!
        #expect(!Reconciler.matches(live: live, expected: .regular(current: price("price-1", start: "2026-01-01"), scheduled: changed), today: today))
        #expect(!Reconciler.matches(live: live, expected: .regular(current: price("price-9", start: "2026-01-01"), scheduled: price("price-2", start: "2026-11-01")), today: today))
        #expect(!Reconciler.matches(live: live, expected: .intro(current: nil, future: nil), today: today))
    }

    @Test func pendingAscIdIsAWildcardOnNaturalKeyFields() {
        let live = CellState.regular(current: price("price-1", start: "2026-01-01"),
                                     scheduled: price("price-n5", start: "2026-11-01", pp: "pp-sub-y-CZE-12", preserved: true))
        var expected = price("", start: "2026-11-01", pp: "pp-sub-y-CZE-12")
        expected.rawPlanType = nil
        #expect(Reconciler.matches(live: live, expected: .regular(current: price("price-1", start: "2026-01-01"), scheduled: expected), today: today))
        expected.pricePointId = "pp-sub-y-CZE-13"
        #expect(!Reconciler.matches(live: live, expected: .regular(current: price("price-1", start: "2026-01-01"), scheduled: expected), today: today))
    }

    @Test func regularPostIsSatisfiedByMatchingRow() {
        let request = NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront, pricePointId: "pp-sub-y-CZE-12",
                                      startDate: d("2026-11-01"), preserveCurrentPrice: true)
        let found = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: price("price-n5", start: "2026-11-01", pp: "pp-sub-y-CZE-12"))
        let other = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: price("price-n6", start: "2026-11-02", pp: "pp-sub-y-CZE-12"))
        #expect(Reconciler.isSatisfied(.createRegularPrice(request), live: found, today: today))
        #expect(Reconciler.createdAscId(.createRegularPrice(request), live: found, today: today) == "price-n5")
        #expect(!Reconciler.isSatisfied(.createRegularPrice(request), live: other, today: today))
    }

    @Test func deleteIsSatisfiedWhenIdIsGone() {
        let with = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: price("price-2", start: "2026-11-01"))
        let without = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: nil)
        #expect(!Reconciler.isSatisfied(.deleteRegularPrice(ascId: "price-2"), live: with, today: today))
        #expect(Reconciler.isSatisfied(.deleteRegularPrice(ascId: "price-2"), live: without, today: today))
        #expect(Reconciler.isSatisfied(.deleteIntro(ascId: "intro-1"), live: .intro(current: nil, future: intro("intro-2", start: "2026-11-01")), today: today))
        #expect(!Reconciler.isSatisfied(.deleteIntro(ascId: "intro-2"), live: .intro(current: nil, future: intro("intro-2", start: "2026-11-01")), today: today))
    }

    @Test func introPostMatchesNaturalKeyAndNullStartMeansCreatedNotLater() {
        let offer = NewIntroOffer(subscriptionId: "sub-y", territory: "DEU", planType: .upfront, mode: .freeTrial, duration: .oneWeek,
                                  numberOfPeriods: 1, startDate: nil, endDate: nil, pricePointId: nil)
        #expect(Reconciler.isSatisfied(.createIntro(offer), live: .intro(current: intro("intro-n1", start: "2026-10-09"), future: nil), today: today))
        #expect(Reconciler.isSatisfied(.createIntro(offer), live: .intro(current: intro("intro-n1", start: nil), future: nil), today: today))
        #expect(!Reconciler.isSatisfied(.createIntro(offer), live: .intro(current: nil, future: intro("intro-n1", start: "2026-11-01")), today: today))
        #expect(Reconciler.createdAscId(.createIntro(offer), live: .intro(current: intro("intro-n1", start: nil), future: nil), today: today) == "intro-n1")
    }

    @Test func endIntroNeedsTheExactEndDate() {
        let payload = WritePayload.endIntro(ascId: "intro-1", endDate: d("2026-11-01"))
        #expect(Reconciler.isSatisfied(payload, live: .intro(current: intro("intro-1", start: "2026-01-01", end: "2026-11-01"), future: nil), today: today))
        #expect(!Reconciler.isSatisfied(payload, live: .intro(current: intro("intro-1", start: "2026-01-01", end: "2026-11-02"), future: nil), today: today))
        #expect(!Reconciler.isSatisfied(payload, live: .intro(current: intro("intro-1", start: "2026-01-01"), future: nil), today: today))
    }

    @Test func promoChecksCodeAndFullPriceSet() {
        let create = NewPromoOffer(subscriptionId: "sub-y", offerCode: "spring_v1", name: "spring_v1", mode: .payAsYouGo,
                                   duration: .oneYear, numberOfPeriods: 1, planType: .upfront, prices: [])
        let live = CellState.promo(offer("promo-1", prices: [("CZE", "pp-a"), ("USA", "pp-b")]))
        #expect(Reconciler.isSatisfied(.createPromo(create), live: live, today: today))
        #expect(Reconciler.createdAscId(.createPromo(create), live: live, today: today) == "promo-1")
        #expect(!Reconciler.isSatisfied(.createPromo(create), live: .promo(nil), today: today))
        let same = [NewPromoPrice(territory: "USA", pricePointId: "pp-b"), NewPromoPrice(territory: "CZE", pricePointId: "pp-a")]
        let different = [NewPromoPrice(territory: "USA", pricePointId: "pp-c"), NewPromoPrice(territory: "CZE", pricePointId: "pp-a")]
        let partial = [NewPromoPrice(territory: "USA", pricePointId: "pp-b")]
        #expect(Reconciler.isSatisfied(.replacePromoPrices(ascId: "promo-1", prices: same), live: live, today: today))
        #expect(!Reconciler.isSatisfied(.replacePromoPrices(ascId: "promo-1", prices: different), live: live, today: today))
        #expect(!Reconciler.isSatisfied(.replacePromoPrices(ascId: "promo-1", prices: partial), live: live, today: today))
        #expect(!Reconciler.isSatisfied(.replacePromoPrices(ascId: "promo-2", prices: same), live: live, today: today))
        #expect(Reconciler.isSatisfied(.deletePromo(ascId: "promo-1"), live: .promo(nil), today: today))
        #expect(!Reconciler.isSatisfied(.deletePromo(ascId: "promo-1"), live: live, today: today))
    }

    @Test func iapScheduleMatchesWholeSchedule() {
        let target = NewIAPSchedule(iapId: "iap-life", baseTerritory: "USA", manualPrices: [
            NewIAPManualPrice(territory: "USA", pricePointId: "pp-u", startDate: nil, endDate: nil),
            NewIAPManualPrice(territory: "CZE", pricePointId: "pp-c", startDate: d("2026-11-10"), endDate: nil)])
        let live = IAPSchedule(iapId: "iap-life", scheduleId: "sched-n3", baseTerritory: "USA", manualPrices: [
            IAPManualPrice(ascId: "m1", territory: "CZE", pricePointId: "pp-c", startDate: d("2026-11-10"), endDate: nil, customerPrice: p999),
            IAPManualPrice(ascId: "m2", territory: "USA", pricePointId: "pp-u", startDate: nil, endDate: nil, customerPrice: p999)])
        #expect(Reconciler.isSatisfied(.replaceIAPSchedule(target), live: .iapSchedule(live), today: today))
        #expect(Reconciler.createdAscId(.replaceIAPSchedule(target), live: .iapSchedule(live), today: today) == "sched-n3")
        var otherBase = live
        otherBase.baseTerritory = "CZE"
        #expect(!Reconciler.isSatisfied(.replaceIAPSchedule(target), live: .iapSchedule(otherBase), today: today))
    }

    @Test func resolveReportsFoundUnchangedOrDiverged() {
        let request = NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront, pricePointId: "pp-sub-y-CZE-12",
                                      startDate: d("2026-11-01"), preserveCurrentPrice: true)
        let before = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: nil)
        let target = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: price("", start: "2026-11-01", pp: "pp-sub-y-CZE-12"))
        let item = PlannedItem(seq: 1, cell: .regular(subscriptionId: "sub-y", territory: "CZE", planType: .upfront),
                               payload: .createRegularPrice(request), before: before, target: target)
        #expect(Reconciler.resolve(item, live: before, today: today) == .unchanged)
        let written = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: price("price-n9", start: "2026-11-01", pp: "pp-sub-y-CZE-12"))
        #expect(Reconciler.resolve(item, live: written, today: today) == .targetFound(ascId: "price-n9"))
        let foreign = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: price("price-x", start: "2026-12-01", pp: "pp-sub-y-CZE-20"))
        #expect(Reconciler.resolve(item, live: foreign, today: today) == .diverged)
    }

    @Test func fillCreatedReplacesOnlyPendingIds() {
        let state = CellState.regular(current: price("price-1", start: "2026-01-01"), scheduled: price("", start: "2026-11-01"))
        #expect(Reconciler.fillCreated(state, ascId: "price-n9")
                == .regular(current: price("price-1", start: "2026-01-01"), scheduled: price("price-n9", start: "2026-11-01")))
        #expect(Reconciler.fillCreated(state, ascId: nil) == state)
    }

    @Test func liveViewAppliesFreshRowsAndDropsOverrides() {
        let cell = CellKey.regular(subscriptionId: "sub-y", territory: "CZE", planType: .upfront)
        let snapshot = CatalogSnapshot(syncId: 1, takenAt: Date(), subscriptions: [:], iaps: [:], territories: ["CZE": "CZK"],
                                       regularRows: [price("price-1", start: "2026-01-01")], introRows: [], promoOffers: [],
                                       iapSchedules: [:], pricePoints: PricePointIndex([]), offerCodesEverSeen: [])
        var view = LiveView(snapshot: snapshot)
        #expect(view.state(cell, today: today) == .regular(current: price("price-1", start: "2026-01-01"), scheduled: nil))
        view.set(cell, .regular(current: nil, scheduled: nil))
        #expect(view.state(cell, today: today) == .regular(current: nil, scheduled: nil))
        view.apply(.regular(subscriptionId: "sub-y", rows: [price("price-1", start: "2026-01-01"), price("price-7", start: "2026-11-01")]))
        #expect(view.state(cell, today: today) == .regular(current: price("price-1", start: "2026-01-01"), scheduled: price("price-7", start: "2026-11-01")))
    }
}
