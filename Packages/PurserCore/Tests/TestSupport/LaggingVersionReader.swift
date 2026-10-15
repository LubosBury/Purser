import Foundation
import Domain
import ASCClient

/// Answers the first `lag` owner reads that show a version missing from `known` without that version and its texts, as a
/// read right after the POST may (synthetic: App Store Connect gives no read-after-write promise). Counts those reads.
public struct LaggingVersionReader: ASCReading {
    let inner: any ASCReading
    let known: Set<String>
    let lag: Locked<Int>
    /// Owner reads that showed a version missing from `known`, hidden or not.
    public let readsWithNewVersion = Locked(0)

    public init(inner: any ASCReading, known: Set<String>, lag: Int) {
        self.inner = inner
        self.known = known
        self.lag = Locked(lag)
    }

    public func metadata(owner: LocalizationOwner) async throws -> OwnerMetadata {
        let read = try await inner.metadata(owner: owner)
        let unknown = Set(read.versions.map(\.ascId)).subtracting(known)
        guard !unknown.isEmpty else { return read }
        readsWithNewVersion.update { $0 += 1 }
        var hide = false
        lag.update { remaining in
            hide = remaining > 0
            if hide { remaining -= 1 }
        }
        guard hide else { return read }
        return OwnerMetadata(owner: owner, versions: read.versions.filter { known.contains($0.ascId) },
                             localizations: read.localizations.filter { !unknown.contains($0.versionId) })
    }

    public func app(id: String) async throws -> ASCApp { try await inner.app(id: id) }
    public func territories() async throws -> [ASCTerritory] { try await inner.territories() }
    public func subscriptionGroups(appId: String) async throws -> [ASCSubscriptionGroup] { try await inner.subscriptionGroups(appId: appId) }
    public func subscriptions(group: ASCSubscriptionGroup) async throws -> [SubscriptionInfo] { try await inner.subscriptions(group: group) }
    public func regularPrices(subscription: SubscriptionInfo) async throws -> [RegularPriceRow] { try await inner.regularPrices(subscription: subscription) }
    public func introductoryOffers(subscription: SubscriptionInfo) async throws -> [IntroOfferRow] { try await inner.introductoryOffers(subscription: subscription) }
    public func promotionalOffers(subscription: SubscriptionInfo) async throws -> [PromoOffer] { try await inner.promotionalOffers(subscription: subscription) }
    public func pricePoints(subscriptionId: String, territories: [TerritoryCode], planType: PlanType?) async throws -> [PricePoint] {
        try await inner.pricePoints(subscriptionId: subscriptionId, territories: territories, planType: planType)
    }
    public func inAppPurchases(appId: String) async throws -> [IAPInfo] { try await inner.inAppPurchases(appId: appId) }
    public func iapPriceSchedule(iapId: String) async throws -> IAPSchedule? { try await inner.iapPriceSchedule(iapId: iapId) }
    public func iapPricePoints(iapId: String, territories: [TerritoryCode]) async throws -> [PricePoint] {
        try await inner.iapPricePoints(iapId: iapId, territories: territories)
    }
    public func subscriptionAvailability(subscriptionId: String) async throws -> ProductAvailability? {
        try await inner.subscriptionAvailability(subscriptionId: subscriptionId)
    }
    public func iapAvailability(iapId: String) async throws -> ProductAvailability? { try await inner.iapAvailability(iapId: iapId) }
    public func reviewScreenshot(of owner: LocalizationOwner) async throws -> ReviewScreenshot? { try await inner.reviewScreenshot(of: owner) }
}
