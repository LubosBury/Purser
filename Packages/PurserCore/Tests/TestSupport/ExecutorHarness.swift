import Foundation
import GRDB
import Domain
import Store
import Audit
import PurserSecurity
import ASCClient
import Catalog
import Policy
import Planner

public enum HarnessError: Error { case noSnapshot }

/// One synthetic workspace (FruitJar) over FakeASC with simulated time.
public struct ExecutorHarness: Sendable {
    public static let start = "2026-10-09T08:00:00Z"

    public let clock: TestClock
    public let fake: FakeASC
    public let config: WorkspaceConfig
    public let database: WorkspaceDatabase
    public let audit: AuditLog
    public let store: PlanStore
    public let catalog: CatalogStore
    public let appGuard: AppGuard
    public let budget: RateBudget
    public let reader: LiveASCClient
    public let writer: LiveASCClient
    public let sync: SyncEngine

    /// `keyKind: .individual` signs with "sub": "user" and no issuer (both JWT shapes go through FakeASC).
    public static func make(model: FakeModel = FakeSeed.fruitJar(), isProduction: Bool = false, keyKind: KeyKind = .team,
                            clock: TestClock = TestClock.at(start)) async throws -> ExecutorHarness {
        let fake = FakeASC(model: model, now: clock.nowFunction)
        let issuer = "11111111-2222-3333-4444-555555555555"
        let identity: JWTIdentity = keyKind == .team ? .team(issuerId: issuer) : .individual
        let config = WorkspaceConfig(id: UUID(uuidString: "6F1C0F55-0000-4000-8000-000000000001")!, name: "FruitJar",
                                     colorHex: "#FF8800", isProduction: isProduction, appId: FakeSeed.appId,
                                     bundleId: "com.example.fruitjar", keyKind: keyKind, keyId: "TESTKEY001",
                                     issuerId: keyKind == .team ? issuer : nil, importMapping: nil, googleClientId: nil,
                                     slackWebhookEnabled: false, nightlySyncHourUTC: 3)
        let database = try WorkspaceDatabase.inMemory()
        let audit = AuditLog(database: database, actor: { "tester@example.com" }, now: clock.nowFunction)
        let appGuard = AppGuard(appId: FakeSeed.appId)
        let budget = RateBudget(now: clock.nowFunction, sleep: clock.sleepFunction)
        let products = Set(model.subscriptions.map(\.id) + model.iaps.map(\.id))
        let children = Set(model.regularPrices.map(\.id) + model.intros.map(\.id) + model.promos.map(\.id) + model.iapSchedules.map(\.id))
        let readHTTP = try await WriteTestClients.http(transport: fake, readOnly: true, products: products, children: children,
                                                       budget: budget, appGuard: appGuard, identity: identity, now: clock.nowFunction)
        let writeHTTP = try await WriteTestClients.http(transport: fake, readOnly: false, products: products, children: children,
                                                        budget: budget, appGuard: appGuard, identity: identity, now: clock.nowFunction)
        let reader = LiveASCClient(http: readHTTP)
        return ExecutorHarness(clock: clock, fake: fake, config: config, database: database, audit: audit,
                               store: PlanStore(database: database), catalog: CatalogStore(database: database),
                               appGuard: appGuard, budget: budget, reader: reader, writer: LiveASCClient(http: writeHTTP),
                               sync: SyncEngine(database: database, reader: reader, audit: audit, config: config, now: clock.nowFunction))
    }

    public var today: CalendarDate { CalendarDate.today(now: clock.now()) }

    @discardableResult
    public func initialSync() async throws -> CatalogSnapshot {
        _ = try await sync.sync(trigger: .manual, scope: .all)
        return try snapshot()
    }

    public func snapshot() throws -> CatalogSnapshot {
        guard let snapshot = try catalog.latestSnapshot() else { throw HarnessError.noSnapshot }
        return snapshot
    }

    @discardableResult
    public func insertPlan(items: [PlannedItem], state: PlanState = .draft, pause: PauseReason? = nil,
                           level: ConfirmationLevel = .c0, verdicts: [Verdict] = [], excluded: [CellKey] = [],
                           binding: PlanBinding? = nil, origin: PlanOrigin = .importTable, createdAt: Date? = nil,
                           heartbeatAt: Date? = nil) throws -> String {
        let id = "plan-\(UUID().uuidString.prefix(8).lowercased())"
        let spec = try JSONCoding.string(PlanSpec.withdraw(WithdrawPlanSpec(planId: "plan-origin", itemSeqs: [])))
        let plan = StoredPlan(id: id, origin: origin, specJSON: spec, importJSON: nil, binding: binding ?? PlanBinding(config: config),
                              baseSyncId: (try? snapshot().syncId) ?? 0, state: state, pauseReason: pause, endReason: nil,
                              planHash: "test-plan-hash", verdictHash: PolicyEngine.hash(verdicts), verdicts: verdicts,
                              excluded: excluded, productStates: [:], reason: nil, confirmationLevel: level, appBuild: "test",
                              estimateRequests: items.count, estimateMinutes: 1, replanOf: nil,
                              createdAt: createdAt ?? clock.now(), updatedAt: clock.now(), heartbeatAt: heartbeatAt)
        try store.insert(plan, items: items)
        return id
    }

    /// Test-only: edits a stored plan in place (state, pause reason, spec).
    public func updatePlan(_ planId: String, _ change: (inout StoredPlan) -> Void) throws {
        guard var plan = try store.plan(id: planId) else { return }
        change(&plan)
        let updated = plan
        try database.writer.write { db in try store.update(updated, in: db) }
    }

    /// Test-only: every row of every table as text (secret scans).
    public func dumpDatabase() throws -> String {
        try database.writer.read { db in
            var text = ""
            for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"") { text += row.description + "\n" }
            }
            return text
        }
    }

    /// Test-only: forces an item state (e.g. InFlight left behind by a crash).
    public func setItemState(planId: String, seq: Int, _ state: ItemState, ascId: String? = nil) throws {
        guard var stored = try store.items(planId: planId).first(where: { $0.item.seq == seq }) else { return }
        stored.state = state
        if let ascId { stored.ascId = ascId }
        try database.writer.write { db in try store.update(stored, in: db) }
    }
}
