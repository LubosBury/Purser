import Foundation
import Domain

/// The ASC API client used by the app. M0 implements `ASCReading`; the `ASCWriting` conformance arrives in M2
/// (LiveASCClient+Writes.swift) and may only be called from Sources/Executor.
public struct LiveASCClient: ASCReading, RequestCounting {
    let http: ASCHTTPClient

    public init(http: ASCHTTPClient) {
        self.http = http
    }

    public func currentRequestCount() async -> Int {
        await http.requestCount
    }
}

/// Paths of the K5 endpoint table. Keep in sync with docs/research/asc-api-paths.md; `make check-endpoints` verifies the table.
enum ASCPath {
    static func app(_ id: String) -> String { "/v1/apps/\(id)" }
    static let territories = "/v1/territories"
    static func subscriptionGroups(app: String) -> String { "/v1/apps/\(app)/subscriptionGroups" }
    static func subscriptions(group: String) -> String { "/v1/subscriptionGroups/\(group)/subscriptions" }
    static func subscriptionAvailability(_ subscription: String) -> String { "/v1/subscriptions/\(subscription)/subscriptionAvailability" }
    static func availableTerritories(availability: String) -> String { "/v1/subscriptionAvailabilities/\(availability)/availableTerritories" }
    static func planAvailabilities(_ subscription: String) -> String { "/v1/subscriptions/\(subscription)/planAvailabilities" }
    static func prices(_ subscription: String) -> String { "/v1/subscriptions/\(subscription)/prices" }
    static func introductoryOffers(_ subscription: String) -> String { "/v1/subscriptions/\(subscription)/introductoryOffers" }
    static func promotionalOffers(_ subscription: String) -> String { "/v1/subscriptions/\(subscription)/promotionalOffers" }
    static func promotionalOfferPrices(_ offer: String) -> String { "/v1/subscriptionPromotionalOffers/\(offer)/prices" }
    static func subscriptionPricePoints(_ subscription: String) -> String { "/v1/subscriptions/\(subscription)/pricePoints" }
    static func inAppPurchases(app: String) -> String { "/v1/apps/\(app)/inAppPurchasesV2" }
    static func iapPriceSchedule(_ iap: String) -> String { "/v2/inAppPurchases/\(iap)/iapPriceSchedule" }
    static func iapManualPrices(schedule: String) -> String { "/v1/inAppPurchasePriceSchedules/\(schedule)/manualPrices" }
    static func iapBaseTerritory(schedule: String) -> String { "/v1/inAppPurchasePriceSchedules/\(schedule)/baseTerritory" }
    static func iapPricePoints(_ iap: String) -> String { "/v2/inAppPurchases/\(iap)/pricePoints" }
}
