import Foundation
import GRDB
import Domain
import Store
import Audit
import ASCClient

public struct SyncEngine: Sendable {
    /// Price points rarely change; a product's points are re-read after this age or when a territory has none.
    static let pricePointMaxAge: TimeInterval = 7 * 24 * 3600
    /// Price point lists are the bulk of a cold sync (hundreds of points per territory and product, many pages each),
    /// so several products are read at once. RateBudget still paces every request.
    public static let maxConcurrentPricePointReads = 4

    private let database: WorkspaceDatabase
    private let reader: any ASCReading
    private let audit: AuditLog
    private let config: WorkspaceConfig
    private let now: @Sendable () -> Date
    private let catalog: CatalogStore

    public init(database: WorkspaceDatabase, reader: any ASCReading, audit: AuditLog, config: WorkspaceConfig,
                now: @escaping @Sendable () -> Date) {
        self.database = database
        self.reader = reader
        self.audit = audit
        self.config = config
        self.now = now
        self.catalog = CatalogStore(database: database)
    }

    /// Reads ASC, writes product/observation/price_point/territory/offer_code_registry, raises EXTERNAL and
    /// SCHEDULE_BROKEN findings only for (product, kind) scopes read completely (spec §5).
    public func sync(trigger: SyncTrigger, scope: SyncScope) async throws -> SyncResult {
        let requestsBefore = await requestCount()
        let syncId = try await database.writer.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO sync_run (trigger, status, started_at) VALUES (?, 'running', ?)",
                           arguments: [trigger.rawValue, Timestamp.string(now())])
            let id = db.lastInsertedRowID
            try audit.append(.syncStarted, refs: ["syncId": String(id)],
                             payload: StartedPayload(trigger: trigger.rawValue, scope: Self.describe(scope)), in: db)
            return id
        }
        var run = Run(syncId: syncId, today: CalendarDate.today(now: now()))

        let listing: Listing
        do {
            listing = try await readListing(syncId: syncId, scope: scope)
        } catch {
            try finish(run, status: .failed, requests: await requestCount() - requestsBefore, error: String(describing: error))
            throw error
        }

        let context = try await database.writer.read { db in
            ScopeContext(previous: try CatalogStore.latestCompleteSyncPerScope(db, before: syncId), items: try PurserItems.load(db))
        }
        var pricePointJobs: [PricePointJob] = []
        for subscription in listing.subscriptions where scope.includes(subscription.ascId) {
            await readScope(&run, product: subscription.ascId, kind: ObservationKind.price, context: context) {
                try await reader.regularPrices(subscription: subscription).map { try Observed(.price($0)) }
            }
            await readScope(&run, product: subscription.ascId, kind: ObservationKind.intro, context: context) {
                try await reader.introductoryOffers(subscription: subscription).map { try Observed(.intro($0)) }
            }
            await readScope(&run, product: subscription.ascId, kind: ObservationKind.promo, context: context) {
                try await reader.promotionalOffers(subscription: subscription).map { try Observed(.promo($0)) }
            }
            let planTypes: [PlanType] = subscription.monthlyPlanAvailable ? [.upfront, .monthly] : [.upfront]
            pricePointJobs.append(PricePointJob(product: subscription.ascId, territories: subscription.availableTerritories) { [reader] territories in
                var points: [PricePoint] = []
                for planType in planTypes {
                    points += try await reader.pricePoints(subscriptionId: subscription.ascId, territories: territories, planType: planType)
                }
                return points
            })
        }
        for iap in listing.iaps where scope.includes(iap.ascId) {
            await readScope(&run, product: iap.ascId, kind: ObservationKind.iapSchedule, context: context) {
                try await reader.iapPriceSchedule(iapId: iap.ascId).map { [try Observed(.schedule($0))] } ?? []
            }
            pricePointJobs.append(PricePointJob(product: iap.ascId, territories: Set(listing.territoryCodes)) { [reader] territories in
                try await reader.iapPricePoints(iapId: iap.ascId, territories: territories)
            })
        }
        for (product, failure) in await refreshPricePoints(pricePointJobs) {
            run.failures["\(product)|PRICE_POINTS"] = failure
        }

        let status: SyncStatus = run.failures.isEmpty ? .complete : .partial
        let requests = await requestCount() - requestsBefore
        try finish(run, status: status, requests: requests, error: nil)
        return SyncResult(syncId: syncId, status: status, requestCount: requests, newFindings: run.newFindings)
    }

    // MARK: - Listing (any failure here fails the whole sync before any observation is touched)

    private struct Listing {
        var subscriptions: [SubscriptionInfo]
        var iaps: [IAPInfo]
        var territoryCodes: [TerritoryCode]
    }

    private func readListing(syncId: Int64, scope: SyncScope) async throws -> Listing {
        let app = try await reader.app(id: config.appId)
        guard app.bundleId == config.bundleId else {
            throw SyncError.bundleIdMismatch(expected: config.bundleId, actual: app.bundleId)
        }
        let storedTerritories = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM territory") ?? 0 }
        if scope == .all || storedTerritories == 0 {
            let territories = try await reader.territories()
            try await database.writer.write { db in
                for territory in territories {
                    try db.execute(sql: """
                        INSERT INTO territory (code, currency) VALUES (?, ?)
                        ON CONFLICT(code) DO UPDATE SET currency = excluded.currency
                        """, arguments: [territory.id.rawValue, territory.currency.rawValue])
                }
            }
        }
        var subscriptions: [SubscriptionInfo] = []
        for group in try await reader.subscriptionGroups(appId: config.appId) {
            subscriptions += try await reader.subscriptions(group: group)
        }
        let iaps = try await reader.inAppPurchases(appId: config.appId)
        let listed = subscriptions
        let codes = try await database.writer.write { db -> [TerritoryCode] in
            for subscription in listed {
                try upsertProduct(db, ascId: subscription.ascId, productId: subscription.productId, kind: .subscription,
                                  infoJSON: try JSONCoding.string(subscription), syncId: syncId)
            }
            for iap in iaps {
                try upsertProduct(db, ascId: iap.ascId, productId: iap.productId, kind: .iap, infoJSON: try JSONCoding.string(iap), syncId: syncId)
            }
            return try String.fetchAll(db, sql: "SELECT code FROM territory ORDER BY code").map { TerritoryCode($0) }
        }
        return Listing(subscriptions: listed, iaps: iaps, territoryCodes: codes)
    }

    private func upsertProduct(_ db: Database, ascId: String, productId: String, kind: ProductKind, infoJSON: String, syncId: Int64) throws {
        try db.execute(sql: """
            INSERT INTO product (asc_id, product_id, kind, info_json, first_sync, last_sync) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(asc_id) DO UPDATE SET product_id = excluded.product_id, kind = excluded.kind,
              info_json = excluded.info_json, last_sync = excluded.last_sync
            """, arguments: [ascId, productId, kind.rawValue, infoJSON, syncId, syncId])
    }

    // MARK: - One (product, kind) scope

    private struct Run {
        let syncId: Int64
        let today: CalendarDate
        var completeScopes: Set<String> = []
        var failures: [String: String] = [:]
        var newFindings: [FindingRecord] = []
    }

    private struct ScopeContext: Sendable {
        var previous: [String: Int64]
        var items: PurserItems
    }

    private func readScope(_ run: inout Run, product: String, kind: String, context: ScopeContext,
                           fetch: () async throws -> [Observed]) async {
        let scope = ObservationKind.scope(product: product, kind: kind)
        do {
            let observed = try await fetch()
            let syncId = run.syncId
            let today = run.today
            let findings = try await database.writer.write { db in
                try apply(observed, product: product, kind: kind, syncId: syncId, previousSync: context.previous[scope],
                          items: context.items, today: today, in: db)
            }
            run.completeScopes.insert(scope)
            run.newFindings += findings
        } catch {
            run.failures[scope] = String(describing: error)
        }
    }

    private func apply(_ observed: [Observed], product: String, kind: String, syncId: Int64, previousSync: Int64?,
                       items: PurserItems, today: CalendarDate, in db: Database) throws -> [FindingRecord] {
        let baseline = previousSync == nil
        let label = Observed.label(kind: kind)
        var findings: [FindingRecord] = []
        func raise(_ type: FindingType, _ cell: CellKey, _ message: String) throws {
            if let finding = try catalog.upsertFinding(type: type, rule: nil, cell: cell, message: message, syncId: syncId, in: db) {
                findings.append(finding)
            }
        }

        struct Previous { var id: Int64; var ascId: String; var hash: String; var provenance: Provenance; var cell: CellKey; var row: Observed.Row }
        var previous: [Previous] = []
        if let previousSync {
            for row in try GRDB.Row.fetchAll(db, sql: """
                SELECT * FROM observation WHERE product_asc_id = ? AND kind = ? AND last_sync = ? AND expired = 0
                """, arguments: [product, kind, previousSync]) {
                let record = try CatalogStore.observation(from: row)
                previous.append(Previous(id: record.id, ascId: record.ascId, hash: row["content_hash"], provenance: record.provenance,
                                         cell: record.cell, row: try Observed.decode(kind: kind, rawJSON: record.rawJSON)))
            }
        }
        let previousIdentities = Set(previous.map { "\($0.ascId)|\($0.hash)" })
        let previousAscIds = Set(previous.map(\.ascId))

        for row in observed {
            let hash = Observed.contentHash(row.rawJSON)
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM observation WHERE kind = ? AND asc_id = ? AND content_hash = ?",
                                                 arguments: [kind, row.ascId, hash]) {
                // Unchanged: extend the version range. A row that comes back to an older state is evaluated like a change.
                try db.execute(sql: "UPDATE observation SET last_sync = ?, expired = 0 WHERE id = ?", arguments: [syncId, existing])
                if baseline || previousIdentities.contains("\(row.ascId)|\(hash)") || items.explainsAppearance(row) { continue }
                try raise(.external, row.cell, "\(label) \(row.ascId) went back to an earlier form outside Purser")
                continue
            }
            let provenance: Provenance = baseline ? .baseline : (items.explainsAppearance(row) ? .purser : .external)
            try db.execute(sql: """
                INSERT INTO observation (kind, asc_id, product_asc_id, cell_key, raw_json, content_hash, first_sync, last_sync, provenance)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [kind, row.ascId, product, row.cell.storageKey, row.rawJSON, hash, syncId, syncId, provenance.rawValue])
            if provenance == .external {
                let verb = previousAscIds.contains(row.ascId) ? "changed" : "appeared"
                try raise(.external, row.cell, "\(label) \(row.ascId) \(verb) outside Purser")
            }
        }

        if !baseline {
            let observedIds = Set(observed.map(\.ascId))
            for gone in previous where !observedIds.contains(gone.ascId) {
                if Self.isExpectedDisappearance(gone.row, observed: observed, today: today) {
                    try db.execute(sql: "UPDATE observation SET expired = 1 WHERE id = ?", arguments: [gone.id])
                } else if items.explainsRemoval(gone.row) {
                    continue
                } else if gone.provenance == .purser {
                    try raise(.scheduleBroken, gone.cell, "\(label) \(gone.ascId) written by Purser disappeared")
                } else {
                    try raise(.external, gone.cell, "\(label) \(gone.ascId) disappeared outside Purser")
                }
            }
        }

        if kind == ObservationKind.promo {
            for row in observed {
                if case let .promo(offer) = row.row {
                    try db.execute(sql: "INSERT OR IGNORE INTO offer_code_registry (offer_code, product_asc_id, first_seen_sync) VALUES (?, ?, ?)",
                                   arguments: [offer.offerCode, product, syncId])
                }
            }
        }

        for finding in findings {
            try audit.append(.findingRaised, refs: ["finding": String(finding.id), "cell": finding.cell.storageKey, "syncId": String(syncId)],
                             payload: FindingPayload(type: finding.type.rawValue, message: finding.message), in: db)
        }
        return findings
    }

    /// Disappearances Apple produces on its own: an intro after its endDate, and a non-preserved price row
    /// replaced by a newer row that has already started (spec §5 "expired"; spikes S4a and S6 confirm).
    static func isExpectedDisappearance(_ row: Observed.Row, observed: [Observed], today: CalendarDate) -> Bool {
        switch row {
        case let .intro(offer):
            return offer.endDate.map { $0 <= today } ?? false
        case let .price(old):
            guard !old.preserved else { return false }
            return observed.contains { candidate in
                guard case let .price(new) = candidate.row, new.territory == old.territory, new.planType == old.planType,
                      let newStart = new.startDate, newStart <= today else { return false }
                return old.startDate.map { $0 < newStart } ?? true
            }
        case .promo, .schedule:
            return false
        }
    }

    // MARK: - Price points

    private struct PricePointJob: Sendable {
        var product: String
        var territories: Set<TerritoryCode>
        var fetch: @Sendable ([TerritoryCode]) async throws -> [PricePoint]
    }

    /// Runs the jobs with at most `maxConcurrentPricePointReads` at once; returns the failures by product.
    private func refreshPricePoints(_ jobs: [PricePointJob]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            var failures: [String: String] = [:]
            var pending = jobs.makeIterator()
            var running = 0
            func startNext() {
                guard let job = pending.next() else { return }
                running += 1
                group.addTask { (job.product, await self.refreshPricePoints(job)) }
            }
            for _ in 0..<Self.maxConcurrentPricePointReads { startNext() }
            while running > 0, let (product, failure) = await group.next() {
                running -= 1
                if let failure { failures[product] = failure }
                startNext()
            }
            return failures
        }
    }

    /// Re-reads one product's price points when they are older than `pricePointMaxAge` or a territory has none.
    /// Returns the error text when the read fails; the stored points stay as they were.
    private func refreshPricePoints(_ job: PricePointJob) async -> String? {
        let product = job.product
        let territories = job.territories
        guard !territories.isEmpty else { return nil }
        do {
            let (oldest, stored) = try await database.writer.read { db in
                (try String.fetchOne(db, sql: "SELECT MIN(fetched_at) FROM price_point WHERE product_asc_id = ?", arguments: [product]),
                 Set(try String.fetchAll(db, sql: "SELECT DISTINCT territory FROM price_point WHERE product_asc_id = ?", arguments: [product])
                     .map { TerritoryCode($0) }))
            }
            let current = now()
            if let oldest, current.timeIntervalSince(try Timestamp.date(oldest)) < Self.pricePointMaxAge, territories.isSubset(of: stored) {
                return nil
            }
            let points = try await job.fetch(territories.sorted())
            let fetchedAt = Timestamp.string(current)
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM price_point WHERE product_asc_id = ?", arguments: [product])
                for point in points {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO price_point (id, product_asc_id, territory, plan_type, customer_price, proceeds, fetched_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [point.id, product, point.territory.rawValue, point.planType?.rawValue,
                                         point.customerPrice.description, point.proceeds?.description, fetchedAt])
                }
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    // MARK: - Bookkeeping

    private func finish(_ run: Run, status: SyncStatus, requests: Int, error: String?) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE sync_run SET status = ?, finished_at = ?, request_count = ?, complete_scopes_json = ? WHERE id = ?
                """, arguments: [status.rawValue, Timestamp.string(now()), requests,
                                 try JSONCoding.string(run.completeScopes.sorted()), run.syncId])
            try audit.append(.syncFinished, refs: ["syncId": String(run.syncId)],
                             payload: FinishedPayload(status: status.rawValue, requestCount: requests,
                                                      completeScopes: run.completeScopes.count, newFindings: run.newFindings.count,
                                                      failures: run.failures, error: error), in: db)
        }
    }

    private func requestCount() async -> Int {
        await (reader as? any RequestCounting)?.currentRequestCount() ?? 0
    }

    static func describe(_ scope: SyncScope) -> String {
        switch scope {
        case .all: return "all"
        case let .products(ids): return "products:" + ids.sorted().joined(separator: ",")
        }
    }

    private struct StartedPayload: Encodable { var trigger: String; var scope: String }
    private struct FindingPayload: Encodable { var type: String; var message: String }
    private struct FinishedPayload: Encodable {
        var status: String
        var requestCount: Int
        var completeScopes: Int
        var newFindings: Int
        var failures: [String: String]
        var error: String?
    }
}

extension SyncScope {
    func includes(_ productAscId: String) -> Bool {
        switch self {
        case .all: return true
        case let .products(ids): return ids.contains(productAscId)
        }
    }
}
