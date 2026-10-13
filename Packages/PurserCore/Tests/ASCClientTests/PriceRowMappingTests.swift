import Foundation
import Testing
import Domain
import ASCClient

@Suite struct PriceRowMappingTests {
    @Test func paidPromoRowKeepsPointAndPrice() throws {
        let row = try PromoPriceMapping.make(rowId: "r1", territoryId: "usa", pricePointId: "pp-usa-1", customerPrice: "4.99", offerMode: .payUpFront)
        #expect(row == PromoPrice(ascId: "r1", territory: "USA", pricePointId: "pp-usa-1", customerPrice: Decimal(string: "4.99")))
    }

    @Test func freeTrialPromoRowDropsAnyEchoedPoint() throws {
        let row = try PromoPriceMapping.make(rowId: "r2", territoryId: "CZE", pricePointId: "pp-zero", customerPrice: "0", offerMode: .freeTrial)
        #expect(row.pricePointId == nil)
        #expect(row.customerPrice == nil)
    }

    @Test func paidPromoRowWithoutPointOrTerritoryIsADecodingError() {
        #expect(throws: ASCError.self) {
            try PromoPriceMapping.make(rowId: "r3", territoryId: "USA", pricePointId: nil, customerPrice: nil, offerMode: .payAsYouGo)
        }
        #expect(throws: ASCError.self) {
            try PromoPriceMapping.make(rowId: "r4", territoryId: nil, pricePointId: "pp", customerPrice: nil, offerMode: .payUpFront)
        }
    }

    @Test func iapManualPriceParsesDatesAndPrice() throws {
        let row = try IAPManualPriceMapping.make(rowId: "m1", territoryId: "USA", pricePointId: "lp-usa-99",
                                                 startDate: "2030-03-20", endDate: nil, customerPrice: "99.99")
        #expect(row == IAPManualPrice(ascId: "m1", territory: "USA", pricePointId: "lp-usa-99",
                                      startDate: CalendarDate(year: 2030, month: 3, day: 20), endDate: nil,
                                      customerPrice: Decimal(string: "99.99")!))
    }

    @Test func iapManualPriceRejectsBadDateAndMissingPrice() {
        #expect(throws: ASCError.self) {
            try IAPManualPriceMapping.make(rowId: "m2", territoryId: "USA", pricePointId: "lp", startDate: "2030-3-1", endDate: nil, customerPrice: "1")
        }
        #expect(throws: ASCError.self) {
            try IAPManualPriceMapping.make(rowId: "m3", territoryId: "USA", pricePointId: "lp", startDate: nil, endDate: nil, customerPrice: nil)
        }
    }
}
