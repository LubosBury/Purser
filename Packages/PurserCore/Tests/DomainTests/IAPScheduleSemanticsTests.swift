import Foundation
import Testing
import Domain

@Suite struct IAPScheduleSemanticsTests {
    let today = CalendarDate(year: 2030, month: 3, day: 1)

    var target: NewIAPSchedule {
        NewIAPSchedule(iapId: "iap-1", baseTerritory: "USA", manualPrices: [
            NewIAPManualPrice(territory: "USA", pricePointId: "lp-usa-99", startDate: nil, endDate: nil),
            NewIAPManualPrice(territory: "CZE", pricePointId: "lp-cze-2490", startDate: nil, endDate: nil),
            NewIAPManualPrice(territory: "USA", pricePointId: "lp-usa-79", startDate: CalendarDate(year: 2030, month: 3, day: 20), endDate: nil),
        ])
    }

    func live(_ prices: [IAPManualPrice], base: TerritoryCode = "USA") -> IAPSchedule {
        IAPSchedule(iapId: "iap-1", scheduleId: "sch-1", baseTerritory: base, manualPrices: prices)
    }

    @Test func liveEqualToTargetMatchesEvenWithEchoedStartDateAndHistory() {
        let schedule = live([
            IAPManualPrice(ascId: "p1", territory: "USA", pricePointId: "lp-usa-99", startDate: today, endDate: CalendarDate(year: 2030, month: 3, day: 20), customerPrice: 99.99),
            IAPManualPrice(ascId: "p2", territory: "CZE", pricePointId: "lp-cze-2490", startDate: nil, endDate: nil, customerPrice: 2490),
            IAPManualPrice(ascId: "p3", territory: "USA", pricePointId: "lp-usa-79", startDate: CalendarDate(year: 2030, month: 3, day: 20), endDate: nil, customerPrice: 79.99),
            IAPManualPrice(ascId: "old", territory: "DEU", pricePointId: "lp-deu-1", startDate: nil, endDate: CalendarDate(year: 2030, month: 2, day: 1), customerPrice: 1),
        ])
        #expect(IAPScheduleSemantics.matches(live: schedule, target: target, today: today))
    }

    @Test func extraManualTerritoryOrOtherBaseDoesNotMatch() {
        let prices = [
            IAPManualPrice(ascId: "p1", territory: "USA", pricePointId: "lp-usa-99", startDate: nil, endDate: nil, customerPrice: 99.99),
            IAPManualPrice(ascId: "p2", territory: "CZE", pricePointId: "lp-cze-2490", startDate: nil, endDate: nil, customerPrice: 2490),
            IAPManualPrice(ascId: "p3", territory: "USA", pricePointId: "lp-usa-79", startDate: CalendarDate(year: 2030, month: 3, day: 20), endDate: nil, customerPrice: 79.99),
        ]
        let extra = prices + [IAPManualPrice(ascId: "p4", territory: "JPN", pricePointId: "lp-jpn-1", startDate: nil, endDate: nil, customerPrice: 1)]
        #expect(!IAPScheduleSemantics.matches(live: live(extra), target: target, today: today))
        #expect(!IAPScheduleSemantics.matches(live: live(prices, base: "CZE"), target: target, today: today))
        #expect(!IAPScheduleSemantics.matches(live: nil, target: target, today: today))
    }

    @Test func explicitTargetEndDateMustMatch() {
        let withEnd = NewIAPSchedule(iapId: "iap-1", baseTerritory: "USA", manualPrices: [
            NewIAPManualPrice(territory: "USA", pricePointId: "lp-usa-99", startDate: nil, endDate: CalendarDate(year: 2030, month: 4, day: 1)),
        ])
        let wrong = live([IAPManualPrice(ascId: "p1", territory: "USA", pricePointId: "lp-usa-99", startDate: nil, endDate: nil, customerPrice: 99.99)])
        let right = live([IAPManualPrice(ascId: "p1", territory: "USA", pricePointId: "lp-usa-99", startDate: nil, endDate: CalendarDate(year: 2030, month: 4, day: 1), customerPrice: 99.99)])
        #expect(!IAPScheduleSemantics.matches(live: wrong, target: withEnd, today: today))
        #expect(IAPScheduleSemantics.matches(live: right, target: withEnd, today: today))
    }

    @Test func afterReplaceBuildsWholeScheduleWithPrices() {
        let result = IAPScheduleSemantics.afterReplace(target, scheduleId: "sch-9") { id in id == "lp-cze-2490" ? 2490 : 99.99 }
        #expect(result.scheduleId == "sch-9")
        #expect(result.baseTerritory == "USA")
        #expect(result.manualPrices.count == 3)
        #expect(result.manualPrices.first { $0.territory == "CZE" }?.customerPrice == 2490)
        #expect(IAPScheduleSemantics.matches(live: result, target: target, today: today))
    }
}
