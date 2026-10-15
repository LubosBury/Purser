import Foundation
import Synchronization
import Testing
import ASCClient
import Audit
import Catalog
import Domain
import Store
import PurserTestSupport

/// Forwards to a ScriptedReader; price point reads take a moment and report how many ran at once.
private final class SlowPricePointReader: ASCReading, RequestCounting, Sendable {
    let base: ScriptedReader
    private let inFlight = Mutex((now: 0, peak: 0))

    init(_ script: ScriptedReader.Script) { base = ScriptedReader(script) }

    var peak: Int { inFlight.withLock { $0.peak } }

    private func slowly<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        inFlight.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
        defer { inFlight.withLock { $0.now -= 1 } }
        try await Task.sleep(for: .milliseconds(40))
        return try await work()
    }

    func currentRequestCount() async -> Int { await base.currentRequestCount() }
    func app(id: String) async throws -> ASCApp { try await base.app(id: id) }
    func territories() async throws -> [ASCTerritory] { try await base.territories() }
    func subscriptionGroups(appId: String) async throws -> [ASCSubscriptionGroup] { try await base.subscriptionGroups(appId: appId) }
    func subscriptions(group: ASCSubscriptionGroup) async throws -> [SubscriptionInfo] { try await base.subscriptions(group: group) }
    func regularPrices(subscription: SubscriptionInfo) async throws -> [RegularPriceRow] { try await base.regularPrices(subscription: subscription) }
    func introductoryOffers(subscription: SubscriptionInfo) async throws -> [IntroOfferRow] { try await base.introductoryOffers(subscription: subscription) }
    func promotionalOffers(subscription: SubscriptionInfo) async throws -> [PromoOffer] { try await base.promotionalOffers(subscription: subscription) }
    func pricePoints(subscriptionId: String, territories: [TerritoryCode], planType: PlanType?) async throws -> [PricePoint] {
        try await slowly { try await base.pricePoints(subscriptionId: subscriptionId, territories: territories, planType: planType) }
    }
    func inAppPurchases(appId: String) async throws -> [IAPInfo] { try await base.inAppPurchases(appId: appId) }
    func iapPriceSchedule(iapId: String) async throws -> IAPSchedule? { try await base.iapPriceSchedule(iapId: iapId) }
    func iapPricePoints(iapId: String, territories: [TerritoryCode]) async throws -> [PricePoint] {
        try await slowly { try await base.iapPricePoints(iapId: iapId, territories: territories) }
    }
    func subscriptionAvailability(subscriptionId: String) async throws -> ProductAvailability? {
        try await base.subscriptionAvailability(subscriptionId: subscriptionId)
    }
    func iapAvailability(iapId: String) async throws -> ProductAvailability? { try await base.iapAvailability(iapId: iapId) }
    func reviewScreenshot(of owner: LocalizationOwner) async throws -> ReviewScreenshot? { try await base.reviewScreenshot(of: owner) }
    func metadata(owner: LocalizationOwner) async throws -> OwnerMetadata { try await base.metadata(owner: owner) }
}

@Suite struct SyncPricePointConcurrencyTests {
    private static let ids = (1...8).map { "65000000\(String(format: "%02d", $0))" }

    private func sync(failing: String? = nil) async throws -> (SlowPricePointReader, SyncResult, WorkspaceDatabase) {
        var script = ScriptedReader.Script()
        script.subscriptions = Self.ids.map { Sample.subscription($0, productId: "fruit.\($0)") }
        for (index, id) in Self.ids.enumerated() { script.pricePoints[id] = [Sample.pricePoint(id, territory: "USA", price: "\(20 + index).99")] }
        if let failing { script.failures["pricePoints:\(failing)"] = .http(status: 500, code: "UNEXPECTED_ERROR", title: nil, detail: nil) }
        let reader = SlowPricePointReader(script)
        let database = try WorkspaceDatabase.inMemory()
        let audit = AuditLog(database: database, actor: { "001234.synthetic-owner.0001" }, now: { Sample.fixedNow })
        let engine = SyncEngine(database: database, reader: reader, audit: audit, config: Sample.config(), now: { Sample.fixedNow })
        return (reader, try await engine.sync(trigger: .manual, scope: .all), database)
    }

    @Test func pricePointsOfSeveralProductsAreReadConcurrentlyUpToTheCap() async throws {
        let (reader, result, database) = try await sync()
        #expect(result.status == .complete)
        #expect(reader.peak > 1)
        #expect(reader.peak <= SyncEngine.maxConcurrentPricePointReads)
        let stored = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT product_asc_id) FROM price_point") ?? 0
        }
        #expect(stored == Self.ids.count)
    }

    @Test func aFailedPricePointReadMakesTheSyncPartialAndKeepsTheOthers() async throws {
        let (_, result, database) = try await sync(failing: Self.ids[3])
        #expect(result.status == .partial)
        let stored = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT product_asc_id) FROM price_point") ?? 0
        }
        #expect(stored == Self.ids.count - 1)
    }
}
