import Foundation
import Testing
import Domain
import Catalog
import Planner

@Suite struct IAPScheduleDiffTests {
    let today = CalendarDate(year: 2030, month: 3, day: 1)
    let index = PricePointIndex([
        PricePoint(id: "lp-usa-99", productAscId: "iap-1", territory: "USA", planType: nil, customerPrice: Decimal(string: "99.99")!, proceeds: nil),
        PricePoint(id: "lp-usa-79", productAscId: "iap-1", territory: "USA", planType: nil, customerPrice: Decimal(string: "79.99")!, proceeds: nil),
        PricePoint(id: "lp-deu-89", productAscId: "iap-1", territory: "DEU", planType: nil, customerPrice: Decimal(string: "89.99")!, proceeds: nil),
    ])
    let before = IAPSchedule(iapId: "iap-1", scheduleId: "s1", baseTerritory: "USA", manualPrices: [
        IAPManualPrice(ascId: "m1", territory: "USA", pricePointId: "lp-usa-99", startDate: nil, endDate: nil, customerPrice: Decimal(string: "99.99")!),
        IAPManualPrice(ascId: "m2", territory: "CZE", pricePointId: "lp-cze-2490", startDate: nil, endDate: nil, customerPrice: 2490),
        IAPManualPrice(ascId: "m3", territory: "JPN", pricePointId: "lp-jpn-old", startDate: nil, endDate: CalendarDate(year: 2030, month: 1, day: 1), customerPrice: 1),
    ])
    let after = NewIAPSchedule(iapId: "iap-1", baseTerritory: "USA", manualPrices: [
        NewIAPManualPrice(territory: "USA", pricePointId: "lp-usa-79", startDate: nil, endDate: nil),
        NewIAPManualPrice(territory: "DEU", pricePointId: "lp-deu-89", startDate: nil, endDate: nil),
    ])

    @Test func rowsShowWholeScheduleBeforeAndAfter() {
        let diff = IAPScheduleDiff.make(before: before, after: after, pricePoints: index,
                                        allTerritories: ["USA", "CZE", "DEU", "JPN"], today: today)
        #expect(diff.baseBefore == "USA")
        #expect(diff.baseAfter == "USA")
        #expect(diff.rows.map(\.territory) == ["CZE", "DEU", "USA"])
        #expect(diff.rows.map(\.change) == [.removed, .added, .changed])
        let usa = diff.rows[2]
        #expect(usa.before == Decimal(string: "99.99"))
        #expect(usa.after == Decimal(string: "79.99"))
        #expect(usa.deltaPercent == Decimal(string: "-20"))
    }

    @Test func autoPricedTerritoriesAreThoseWithoutManualPriceAfter() {
        let diff = IAPScheduleDiff.make(before: before, after: after, pricePoints: index,
                                        allTerritories: ["USA", "CZE", "DEU", "JPN"], today: today)
        #expect(diff.autoPricedTerritories == ["CZE", "JPN"])
    }

    @Test func futurePriceIsItsOwnRow() {
        let withFuture = NewIAPSchedule(iapId: "iap-1", baseTerritory: "USA", manualPrices: [
            NewIAPManualPrice(territory: "USA", pricePointId: "lp-usa-99", startDate: nil, endDate: nil),
            NewIAPManualPrice(territory: "USA", pricePointId: "lp-usa-79", startDate: CalendarDate(year: 2030, month: 4, day: 1), endDate: nil),
        ])
        let diff = IAPScheduleDiff.make(before: before, after: withFuture, pricePoints: index, allTerritories: ["USA", "CZE"], today: today)
        let usaRows = diff.rows.filter { $0.territory == "USA" }
        #expect(usaRows.map(\.change) == [.unchanged, .added])
        #expect(usaRows[1].startDate == CalendarDate(year: 2030, month: 4, day: 1))
    }
}
