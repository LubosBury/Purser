import Foundation
import Testing
import Catalog
import Domain
import PurserTestSupport

@Suite struct CatalogSnapshotTests {
    private let day = CalendarDate(year: 2026, month: 10, day: 9)

    private func makeSnapshot() -> CatalogSnapshot {
        CatalogSnapshot(
            syncId: 7, takenAt: Sample.fixedNow, subscriptions: ["6500000001": Sample.subscription()], iaps: ["6600000001": Sample.iap()],
            territories: ["USA": "USD", "CZE": "CZK", "DEU": "EUR"],
            regularRows: [
                Sample.regular("usa-old", territory: "USA", price: "24.99", start: nil, preserved: true),
                Sample.regular("usa-now", territory: "USA", price: "29.99", start: "2026-03-01"),
                Sample.regular("usa-next", territory: "USA", price: "34.99", start: "2026-11-01"),
                Sample.regular("cze-now", territory: "CZE", price: "799", start: nil),
            ],
            introRows: [
                Sample.intro("intro-usa-now", territory: "USA", start: "2026-01-01", end: "2026-11-01"),
                Sample.intro("intro-usa-next", territory: "USA", mode: .payUpFront, duration: .threeMonths, price: "9.99", start: "2026-11-01"),
                Sample.intro("intro-cze-ended", territory: "CZE", start: "2026-01-01", end: "2026-10-09"),
            ],
            promoOffers: [Sample.promo("promo-b", code: "B_v1", prices: [("USA", "14.99")]), Sample.promo("promo-a", code: "A_v1", prices: [("USA", "9.99")])],
            iapSchedules: ["6600000001": Sample.schedule(prices: [("USA", "49.99")])],
            pricePoints: PricePointIndex([]), offerCodesEverSeen: ["A_v1", "B_v1", "OLD_v1"])
    }

    @Test func currentAndScheduledRegularPrice() {
        let snapshot = makeSnapshot()
        #expect(snapshot.currentRegular(subscriptionId: "6500000001", territory: "USA", planType: .upfront, on: day)?.ascId == "usa-now")
        #expect(snapshot.scheduledRegular(subscriptionId: "6500000001", territory: "USA", planType: .upfront, on: day)?.ascId == "usa-next")
        #expect(snapshot.currentRegular(subscriptionId: "6500000001", territory: "CZE", planType: .upfront, on: day)?.ascId == "cze-now")
        #expect(snapshot.scheduledRegular(subscriptionId: "6500000001", territory: "CZE", planType: .upfront, on: day) == nil)
        #expect(snapshot.currentRegular(subscriptionId: "6500000001", territory: "DEU", planType: .upfront, on: day) == nil)
        // Once the scheduled change starts it becomes current.
        let later = CalendarDate(year: 2026, month: 11, day: 1)
        #expect(snapshot.currentRegular(subscriptionId: "6500000001", territory: "USA", planType: .upfront, on: later)?.ascId == "usa-next")
        #expect(snapshot.regularPrice(subscriptionId: "6500000001", territory: "USA", planType: .upfront, on: day) == Decimal(string: "29.99")!)
        #expect(snapshot.regularPrice(subscriptionId: "6500000001", territory: "USA", planType: .upfront, on: later) == Decimal(string: "34.99")!)
    }

    @Test func currentAndFutureIntro() {
        let snapshot = makeSnapshot()
        #expect(snapshot.currentIntro(subscriptionId: "6500000001", territory: "USA", planType: .upfront, on: day)?.ascId == "intro-usa-now")
        #expect(snapshot.futureIntro(subscriptionId: "6500000001", territory: "USA", planType: .upfront, on: day)?.ascId == "intro-usa-next")
        // endDate is exclusive: an intro ending today is no longer current.
        #expect(snapshot.currentIntro(subscriptionId: "6500000001", territory: "CZE", planType: .upfront, on: day) == nil)
    }

    @Test func cellStateForEveryCellKind() {
        let snapshot = makeSnapshot()
        guard case let .regular(current, scheduled) = snapshot.cellState(.regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront), on: day) else {
            Issue.record("wrong case"); return
        }
        #expect(current?.ascId == "usa-now")
        #expect(scheduled?.ascId == "usa-next")
        guard case let .intro(currentIntro, futureIntro) = snapshot.cellState(.intro(subscriptionId: "6500000001", territory: "USA", planType: .upfront), on: day) else {
            Issue.record("wrong case"); return
        }
        #expect(currentIntro?.ascId == "intro-usa-now")
        #expect(futureIntro?.ascId == "intro-usa-next")
        #expect(snapshot.cellState(.promo(subscriptionId: "6500000001", offerCode: "B_v1"), on: day) == .promo(snapshot.promoOffers.first { $0.offerCode == "B_v1" }))
        #expect(snapshot.cellState(.promo(subscriptionId: "6500000001", offerCode: "NOPE"), on: day) == .promo(nil))
        #expect(snapshot.cellState(.iapSchedule(iapId: "6600000001"), on: day) == .iapSchedule(snapshot.iapSchedules["6600000001"]))
    }

    @Test func promoOffersAreSortedByCode() {
        #expect(makeSnapshot().promoOffers(subscriptionId: "6500000001").map(\.offerCode) == ["A_v1", "B_v1"])
        #expect(makeSnapshot().promoOffers(subscriptionId: "6500000009").isEmpty)
    }
}
