import Foundation
import GRDB
import Testing
import Domain
import Store
import Audit
import Catalog
import Importer
import Policy
@testable import Planner
import PurserTestSupport

/// Times the steps of opening a stored plan (PlanningModel.open and the reload before it) on a synthetic catalog.
/// Skipped unless PURSER_BENCH=1: `PURSER_BENCH=1 swift test --package-path Packages/PurserCore --filter PlanOpenBenchmark`.
@Suite struct PlanOpenBenchmark {
    static let enabled = ProcessInfo.processInfo.environment["PURSER_BENCH"] == "1"

    @Test(.enabled(if: PlanOpenBenchmark.enabled), arguments: [(["D"], 100), (["D", "F", "H"], 100), (["D"], 800), (["D", "F", "H"], 800)])
    func openingAStoredImportPlan(columns: [String], ladder: Int) async throws {
        let (table, _) = try await SyntheticImport.importedTable()
        var catalog = SyntheticCatalog.fromSyntheticTable(table)
        // Apple's ladders have several hundred points per territory; the synthetic one has 100.
        let extra = (100..<ladder).map { Decimal($0) + SyntheticCatalog.d("0.99") }
        for product in SyntheticImport.regularColumns.values {
            catalog.addLadder(product: product, territories: table.rows.map(\.territory), planType: .upfront, prices: extra)
        }
        let config = SyntheticCatalog.config(mapping: SyntheticImport.mapping())
        let spec = PlanSpec.importTable(ImportPlanSpec(table: table, writeColumns: columns, filter: PlanFilter(),
                                                       startDate: today.adding(days: 7), preserveCurrentPrice: nil, canary: false))

        let database = try WorkspaceDatabase.inMemory()
        let store = PlanStore(database: database)
        let catalogStore = CatalogStore(database: database)
        let audit = AuditLog(database: database, actor: { "owner" }, now: { Date() })
        try seed(catalog, into: database)
        let persistence = PlanPersistence(store: store, audit: audit, appBuild: "bench")
        let planner = Planner(policy: PolicyEngine())

        var snapshot = catalog.snapshot()
        let reload = try measure { snapshot = try #require(try catalogStore.latestSnapshot()) }
        let listing = try measure { _ = try store.plans(states: nil); _ = try catalogStore.findings(includeAcked: false) }
        let context = PlanningContext(snapshot: snapshot, config: config, today: today)
        let id = try persistence.saveDraft(try planner.plan(spec, context: context), binding: PlanBinding(config: config), reason: nil, replanOf: nil)

        var plan: StoredPlan?
        var items: [PlannedItem] = []
        var decoded = spec
        var rows: [PlanDiffRow] = []
        let readPlan = try measure { plan = try store.plan(id: id) }
        let readItems = try measure { items = try store.items(planId: id).map(\.item) }
        let stored = try #require(plan)
        let decode = try measure { decoded = try JSONCoding.decode(PlanSpec.self, from: stored.specJSON) }
        let draft = try measure {
            _ = try LiveIntroCanaries.unlockedProducts(store: store)
            _ = try planner.plan(decoded, context: context)
        }
        let diff = try measure {
            rows = PlanDiff.rows(items: items, verdicts: stored.verdicts, spec: decoded, snapshot: snapshot, config: config, today: today)
        }
        #expect(rows.count == items.count)

        print("""
        PLAN-OPEN-BENCH items=\(items.count) pricePoints=\(catalog.pricePoints.count) \
        latestSnapshot=\(reload) plans+findings=\(listing) plan=\(readPlan) items=\(readItems) decodeSpec=\(decode) \
        draftForCheckDiffs=\(draft) PlanDiff.rows=\(diff)
        """)
    }

    /// Best of three, in milliseconds.
    private func measure(_ body: () throws -> Void) throws -> String {
        var best = Duration.seconds(3600)
        for _ in 0..<3 {
            let start = ContinuousClock.now
            try body()
            best = min(best, ContinuousClock.now - start)
        }
        let ms = Double(best.components.seconds) * 1000 + Double(best.components.attoseconds) / 1e15
        return String(format: "%.1fms", ms)
    }

    /// Writes the catalog the way a complete sync leaves it, so `latestSnapshot()` has real rows to decode.
    private func seed(_ catalog: SyntheticCatalog, into database: WorkspaceDatabase) throws {
        try database.writer.write { db in
            let now = Timestamp.string(Date())
            let scopes = catalog.subscriptions.keys.map { "\($0)|\(ObservationKind.price)" }
            try db.execute(sql: """
                INSERT INTO sync_run (trigger, status, started_at, finished_at, complete_scopes_json) VALUES ('manual', 'complete', ?, ?, ?)
                """, arguments: [now, now, try JSONCoding.string(scopes)])
            let syncId = db.lastInsertedRowID
            for (code, currency) in catalog.territories {
                try db.execute(sql: "INSERT INTO territory (code, currency) VALUES (?, ?)", arguments: [code.rawValue, currency.rawValue])
            }
            for info in catalog.subscriptions.values {
                try db.execute(sql: "INSERT INTO product (asc_id, product_id, kind, info_json, first_sync, last_sync) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [info.ascId, info.productId, ProductKind.subscription.rawValue, try JSONCoding.string(info), syncId, syncId])
            }
            for row in catalog.regularRows {
                let cell = CellKey.regular(subscriptionId: row.subscriptionId, territory: row.territory, planType: row.planType)
                try db.execute(sql: """
                    INSERT INTO observation (kind, asc_id, product_asc_id, cell_key, raw_json, content_hash, first_sync, last_sync, provenance)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [ObservationKind.price, row.ascId, row.subscriptionId, cell.storageKey, try JSONCoding.string(row),
                                     row.ascId, syncId, syncId, Provenance.baseline.rawValue])
            }
            for point in catalog.pricePoints {
                try db.execute(sql: """
                    INSERT INTO price_point (id, product_asc_id, territory, plan_type, customer_price, proceeds, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [point.id, point.productAscId, point.territory.rawValue, point.planType?.rawValue,
                                     "\(point.customerPrice)", point.proceeds.map { "\($0)" }, now])
            }
        }
    }
}
