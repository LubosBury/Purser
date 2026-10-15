import Foundation
import Synchronization
import ASCClient
import Domain

/// An in-memory `ASCReading` whose answers a test edits between syncs. Every call is logged and counts as one request.
public final class ScriptedReader: ASCReading, RequestCounting, Sendable {
    public struct Script: Sendable {
        public var app = ASCApp(id: Sample.appId, bundleId: Sample.bundleId, name: "Fruit Journal")
        public var territories: [ASCTerritory] = [
            ASCTerritory(id: "CZE", currency: "CZK"), ASCTerritory(id: "DEU", currency: "EUR"), ASCTerritory(id: "USA", currency: "USD"),
        ]
        public var groups = [ASCSubscriptionGroup(id: "7000000001", referenceName: "Fruit Premium")]
        public var subscriptions: [SubscriptionInfo] = [Sample.subscription()]
        public var prices: [String: [RegularPriceRow]] = [:]
        public var intros: [String: [IntroOfferRow]] = [:]
        public var promos: [String: [PromoOffer]] = [:]
        public var pricePoints: [String: [PricePoint]] = [:]
        public var iaps: [IAPInfo] = []
        public var schedules: [String: IAPSchedule] = [:]
        /// Product ASC id -> availability (subscription or in-app purchase); missing = none.
        public var availabilities: [String: ProductAvailability] = [:]
        /// Product ASC id -> review screenshot; missing = none.
        public var screenshots: [String: ReviewScreenshot] = [:]
        /// Versions and texts per owner; an owner without an entry has no version.
        public var metadata: [LocalizationOwner: OwnerMetadata] = [:]
        /// Keys like "regularPrices:6500000001"; the matching call throws the error instead of answering.
        public var failures: [String: ASCError] = [:]

        public init() {}
    }

    private struct State: Sendable {
        var script: Script
        var calls: [String] = []
    }

    private let state: Mutex<State>

    public init(_ script: Script = Script()) {
        state = Mutex(State(script: script))
    }

    public func update(_ change: (inout Script) -> Void) {
        state.withLock { change(&$0.script) }
    }

    public var calls: [String] {
        state.withLock { $0.calls }
    }

    public func currentRequestCount() async -> Int {
        state.withLock { $0.calls.count }
    }

    private func answer<T>(_ call: String, _ pick: (Script) -> T) throws -> T {
        try state.withLock { state in
            state.calls.append(call)
            if let error = state.script.failures[call] { throw error }
            return pick(state.script)
        }
    }

    public func app(id: String) async throws -> ASCApp { try answer("app:\(id)") { $0.app } }
    public func territories() async throws -> [ASCTerritory] { try answer("territories") { $0.territories } }
    public func subscriptionGroups(appId: String) async throws -> [ASCSubscriptionGroup] { try answer("subscriptionGroups:\(appId)") { $0.groups } }
    public func subscriptions(group: ASCSubscriptionGroup) async throws -> [SubscriptionInfo] {
        try answer("subscriptions:\(group.id)") { script in script.subscriptions.filter { $0.groupId == group.id } }
    }
    public func regularPrices(subscription: SubscriptionInfo) async throws -> [RegularPriceRow] {
        try answer("regularPrices:\(subscription.ascId)") { $0.prices[subscription.ascId] ?? [] }
    }
    public func introductoryOffers(subscription: SubscriptionInfo) async throws -> [IntroOfferRow] {
        try answer("introductoryOffers:\(subscription.ascId)") { $0.intros[subscription.ascId] ?? [] }
    }
    public func promotionalOffers(subscription: SubscriptionInfo) async throws -> [PromoOffer] {
        try answer("promotionalOffers:\(subscription.ascId)") { $0.promos[subscription.ascId] ?? [] }
    }
    public func pricePoints(subscriptionId: String, territories: [TerritoryCode], planType: PlanType?) async throws -> [PricePoint] {
        try answer("pricePoints:\(subscriptionId)") { script in
            (script.pricePoints[subscriptionId] ?? []).filter { territories.contains($0.territory) && $0.planType == planType }
        }
    }
    public func inAppPurchases(appId: String) async throws -> [IAPInfo] { try answer("inAppPurchases:\(appId)") { $0.iaps } }
    public func iapPriceSchedule(iapId: String) async throws -> IAPSchedule? { try answer("iapPriceSchedule:\(iapId)") { $0.schedules[iapId] } }
    public func iapPricePoints(iapId: String, territories: [TerritoryCode]) async throws -> [PricePoint] {
        try answer("iapPricePoints:\(iapId)") { script in (script.pricePoints[iapId] ?? []).filter { territories.contains($0.territory) } }
    }
    public func subscriptionAvailability(subscriptionId: String) async throws -> ProductAvailability? {
        try answer("subscriptionAvailability:\(subscriptionId)") { $0.availabilities[subscriptionId] }
    }
    public func iapAvailability(iapId: String) async throws -> ProductAvailability? {
        try answer("iapAvailability:\(iapId)") { $0.availabilities[iapId] }
    }
    public func reviewScreenshot(of owner: LocalizationOwner) async throws -> ReviewScreenshot? {
        // A group has no review screenshot; like LiveASCClient this answers without a request.
        if owner.kind == .group { return nil }
        return try answer("reviewScreenshot:\(owner.key)") { $0.screenshots[owner.ascId] }
    }
    public func metadata(owner: LocalizationOwner) async throws -> OwnerMetadata {
        try answer("metadata:\(owner.key)") { $0.metadata[owner] ?? OwnerMetadata(owner: owner, versions: [], localizations: []) }
    }
}
