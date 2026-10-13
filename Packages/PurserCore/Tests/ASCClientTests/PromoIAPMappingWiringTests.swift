import Foundation
import Testing
import Domain
@testable import ASCClient

/// ASCMapping (M0, LiveASCClient+Reading.swift) must route promo and IAP price rows through
/// PromoPriceMapping / IAPManualPriceMapping (rule O4, spikes S7 and S10).
@Suite struct PromoIAPMappingWiringTests {
    let subscription = SubscriptionInfo(ascId: "2000000002", productId: "com.example.spike.yearlyb", name: "Spike Yearly B",
                                        period: .oneYear, state: .readyToSubmit, groupId: "6000000001", groupName: "Purser Spike",
                                        availableTerritories: ["USA", "CZE"], monthlyPlanAvailable: false)

    func document(_ json: String) throws -> JSONAPIDocument {
        try JSONDecoder().decode(JSONAPIDocument.self, from: Data(json.utf8))
    }

    func offer(mode: String) throws -> JSONAPIResource {
        let json = """
        {"data": {"type": "subscriptionPromotionalOffers", "id": "3000000009",
                  "attributes": {"offerCode": "wiring_v1", "name": "Wiring", "offerMode": "\(mode)", "duration": "ONE_MONTH",
                                 "numberOfPeriods": 1, "targetSubscriptionPlanType": "UPFRONT"}}}
        """
        return try #require(try document(json).data.first)
    }

    @Test func freeTrialRowWithEchoedPointMapsWithoutPoint() throws {
        let prices = try document("""
        {"data": [{"type": "subscriptionPromotionalOfferPrices", "id": "prow-1", "relationships": {
            "territory": {"data": {"type": "territories", "id": "USA"}},
            "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": "pp-zero"}}}}]}
        """)
        let mapped = try ASCMapping.promotionalOffer(try offer(mode: "FREE_TRIAL"), pricePages: [prices], subscription: subscription)
        #expect(mapped.prices == [PromoPrice(ascId: "prow-1", territory: "USA", pricePointId: nil, customerPrice: nil)])
    }

    @Test func paidRowWithoutPointIsADecodingError() throws {
        let prices = try document("""
        {"data": [{"type": "subscriptionPromotionalOfferPrices", "id": "prow-2", "relationships": {
            "territory": {"data": {"type": "territories", "id": "CZE"}}}}]}
        """)
        let paid = try offer(mode: "PAY_AS_YOU_GO")
        #expect(throws: ASCError.self) {
            try ASCMapping.promotionalOffer(paid, pricePages: [prices], subscription: subscription)
        }
    }

    @Test func iapManualPriceKeepsDatesAndIncludedPrice() throws {
        let page = try document("""
        {"data": [{"type": "inAppPurchasePrices", "id": "mprice-1", "attributes": {"startDate": "2030-03-20", "endDate": null},
                   "relationships": {"territory": {"data": {"type": "territories", "id": "USA"}},
                                     "inAppPurchasePricePoint": {"data": {"type": "inAppPurchasePricePoints", "id": "lp-usa-b"}}}}],
         "included": [{"type": "inAppPurchasePricePoints", "id": "lp-usa-b", "attributes": {"customerPrice": "79.99"}}]}
        """)
        #expect(try ASCMapping.iapManualPrices([page]) == [
            IAPManualPrice(ascId: "mprice-1", territory: "USA", pricePointId: "lp-usa-b",
                           startDate: CalendarDate(year: 2030, month: 3, day: 20), endDate: nil,
                           customerPrice: Decimal(string: "79.99")!),
        ])
    }
}
