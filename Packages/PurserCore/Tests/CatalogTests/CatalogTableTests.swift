import Foundation
import Testing
import Catalog
import Domain
import PurserTestSupport

@Suite struct CatalogTableTests {
    private let today = CalendarDate(year: 2026, month: 10, day: 9)

    private func snapshot() -> CatalogSnapshot {
        CatalogSnapshot(
            syncId: 3, takenAt: Sample.fixedNow,
            subscriptions: ["6500000001": Sample.subscription(territories: ["USA", "CZE"])], iaps: ["6600000001": Sample.iap()],
            territories: ["USA": "USD", "CZE": "CZK", "DEU": "EUR"],
            regularRows: [
                Sample.regular("usa-now", territory: "USA", price: "30"),
                Sample.regular("usa-next", territory: "USA", price: "40", start: "2026-11-01", preserved: false),
            ],
            introRows: [
                Sample.intro("intro-usa", territory: "USA", mode: .payUpFront, duration: .threeMonths, price: "15", start: "2026-01-01"),
                Sample.intro("intro-usa-next", territory: "USA", mode: .payUpFront, duration: .threeMonths, price: "20", start: "2026-12-01"),
            ],
            promoOffers: [Sample.promo("promo-1", code: "A_v1", prices: [("USA", "10")])],
            iapSchedules: ["6600000001": IAPSchedule(iapId: "6600000001", scheduleId: "6600000001", baseTerritory: "USA", manualPrices: [
                IAPManualPrice(ascId: "m-usa", territory: "USA", pricePointId: "iap-USA-49.99", startDate: nil, endDate: nil, customerPrice: Decimal(string: "49.99")!),
                IAPManualPrice(ascId: "m-cze", territory: "CZE", pricePointId: "iap-CZE-1290", startDate: CalendarDate(iso: "2026-11-01"), endDate: nil, customerPrice: 1290),
            ])],
            pricePoints: PricePointIndex([]), offerCodesEverSeen: [])
    }

    @Test func subscriptionRowsCoverEveryTerritory() {
        let observations = [ObservationRecord(id: 1, kind: "PRICE", ascId: "usa-now",
                                              cell: .regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront),
                                              rawJSON: "{}", firstSync: 1, lastSync: 3, provenance: .external, expired: false)]
        let findings = [FindingRecord(id: 1, type: .external, rule: nil, cell: .regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront),
                                      fingerprint: "f", message: "m", firstSync: 3, lastSync: 3, planId: nil, ackReason: nil, ackAt: nil)]
        let rows = CatalogTable.subscriptionRows(snapshot: snapshot(), subscriptionId: "6500000001", planType: .upfront, today: today,
                                                 observations: observations, findings: findings)
        #expect(rows.map(\.territory) == ["CZE", "DEU", "USA"])
        let usa = rows[2]
        #expect(usa.currency == "USD")
        #expect(usa.currentPrice == 30)
        #expect(usa.scheduledPrice == 40)
        #expect(usa.scheduledStart == CalendarDate(iso: "2026-11-01"))
        #expect(usa.scheduledPreserved == false)
        #expect(usa.currentIntro?.shareOfRegular == Decimal(string: "0.5")!)
        // The future intro starts after the scheduled increase, so it is measured against 40.
        #expect(usa.futureIntro?.shareOfRegular == Decimal(string: "0.5")!)
        #expect(usa.promoCount == 1)
        #expect(usa.provenance == .external)
        #expect(usa.findingCount == 1)
        #expect(usa.flags.isEmpty)
        #expect(rows[0].flags == ["no price"])
        #expect(rows[1].flags == ["unavailable"])
        #expect(rows[1].isAvailable == false)
    }

    @Test func iapRowsShowManualAndGeneratedPrices() {
        let rows = CatalogTable.iapRows(snapshot: snapshot(), iapId: "6600000001", today: today, observations: [], findings: [])
        #expect(rows.map(\.territory) == ["CZE", "DEU", "USA"])
        #expect(rows[2].currentPrice == Decimal(string: "49.99")!)
        #expect(rows[2].flags == ["base"])
        #expect(rows[0].currentPrice == nil)
        #expect(rows[0].scheduledPrice == 1290)
        #expect(rows[1].flags == ["generated from base"])
    }
}
