import Foundation
import Domain

public struct ASCApp: Hashable, Sendable, Codable {
    public var id: String
    public var bundleId: String
    public var name: String
    public init(id: String, bundleId: String, name: String) { self.id = id; self.bundleId = bundleId; self.name = name }
}

public struct ASCSubscriptionGroup: Hashable, Sendable, Codable {
    public var id: String
    public var referenceName: String
    public init(id: String, referenceName: String) { self.id = id; self.referenceName = referenceName }
}

public struct ASCTerritory: Hashable, Sendable, Codable {
    public var id: TerritoryCode
    public var currency: CurrencyCode
    public init(id: TerritoryCode, currency: CurrencyCode) { self.id = id; self.currency = currency }
}

public protocol ASCReading: Sendable {
    func app(id: String) async throws -> ASCApp
    func territories() async throws -> [ASCTerritory]
    func subscriptionGroups(appId: String) async throws -> [ASCSubscriptionGroup]
    func subscriptions(group: ASCSubscriptionGroup) async throws -> [SubscriptionInfo]
    func regularPrices(subscription: SubscriptionInfo) async throws -> [RegularPriceRow]
    func introductoryOffers(subscription: SubscriptionInfo) async throws -> [IntroOfferRow]
    func promotionalOffers(subscription: SubscriptionInfo) async throws -> [PromoOffer]
    func pricePoints(subscriptionId: String, territories: [TerritoryCode], planType: PlanType?) async throws -> [PricePoint]
    func inAppPurchases(appId: String) async throws -> [IAPInfo]
    func iapPriceSchedule(iapId: String) async throws -> IAPSchedule?
    func iapPricePoints(iapId: String, territories: [TerritoryCode]) async throws -> [PricePoint]
}

public protocol ASCWriting: Sendable {
    func createRegularPrice(_ request: NewRegularPrice) async throws -> RegularPriceRow
    func deleteRegularPrice(ascId: String) async throws
    func createIntroductoryOffer(_ request: NewIntroOffer) async throws -> IntroOfferRow
    func endIntroductoryOffer(ascId: String, endDate: CalendarDate) async throws
    func deleteIntroductoryOffer(ascId: String) async throws
    func createPromotionalOffer(_ request: NewPromoOffer) async throws -> PromoOffer
    func replacePromotionalOfferPrices(ascId: String, prices: [NewPromoPrice]) async throws
    func deletePromotionalOffer(ascId: String) async throws
    func replaceIAPPriceSchedule(_ request: NewIAPSchedule) async throws
}

/// Readers that can report how many HTTP requests they have sent (sync_run.request_count).
public protocol RequestCounting: Sendable {
    func currentRequestCount() async -> Int
}
