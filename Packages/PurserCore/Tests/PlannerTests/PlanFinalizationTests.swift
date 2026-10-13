import Foundation
import Testing
import Domain
import Store
import Audit
import Catalog
import Importer
import Policy
import ASCClient
import GRDB
@testable import Planner
import PurserTestSupport

@Suite struct PlanFinalizationTests {
    @Test func exclusionRemovesDependantsAndRenumbers() {
        let a: CellKey = .intro(subscriptionId: "s", territory: "USA", planType: .upfront)
        let b: CellKey = .regular(subscriptionId: "s", territory: "USA", planType: .upfront)
        let c: CellKey = .regular(subscriptionId: "s", territory: "DEU", planType: .upfront)
        func item(_ seq: Int, _ cell: CellKey, _ deps: [Int]) -> PlannedItem {
            PlannedItem(seq: seq, cell: cell, payload: .deleteRegularPrice(ascId: "x\(seq)"), before: .regular(current: nil, scheduled: nil),
                        target: .regular(current: nil, scheduled: nil), dependsOn: deps)
        }
        let result = Exclusion.apply([a], to: [item(1, a, []), item(2, b, [1]), item(3, c, []), item(4, c, [3]), item(5, b, [2])])
        #expect(result.items.map(\.seq) == [1, 2])
        #expect(result.items.map(\.cell) == [c, c])
        #expect(result.items[1].dependsOn == [1])
        #expect(result.excluded == [a, b])
    }

    @Test func blockCellFromSnappingExcludesOnlyThatCell() throws {
        let draft = try plan(introSpec(.table([TerritoryAmount(territory: "USA", amount: d("0.10")), TerritoryAmount(territory: "DEU", amount: d("23.99"))])),
                             yearly(.readyToSubmit).snapshot())
        #expect(draft.items.map(\.cell.territory) == ["DEU"])
        #expect(draft.excluded == [.intro(subscriptionId: "s", territory: "USA", planType: .upfront)])
        #expect(draft.verdicts("S4").map(\.severity) == [.block(.cell)])
    }

    @Test func blockCellFromPolicyExcludesTheWholeChain() throws {
        var catalog = yearly()
        catalog.setRegular("s", "USA", d("31.99"), start: today.adding(days: 2), ascId: "rp-soon")
        let draft = try plan(regularSpec(["USA": "34.99", "DEU": "34.99"]), catalog.snapshot())
        #expect(draft.items.map(\.cell.territory) == ["DEU"])
        #expect(draft.items[0].seq == 1)
        #expect(draft.excluded == [.regular(subscriptionId: "s", territory: "USA", planType: .upfront)])
        #expect(draft.verdicts("R6").map(\.severity) == [.block(.cell)])
        #expect(draft.verdicts("R5").isEmpty)
    }

    @Test func introWithTwoRowsIsNotReplacedAutomaticallyAndCellIsExcluded() throws {
        var catalog = yearly(.readyToSubmit)
        catalog.addIntro("s", "USA", price: d("23.99"), end: today.adding(days: 30))
        catalog.addIntro("s", "USA", price: d("22.99"), start: today.adding(days: 30), ascId: "io-next")
        let draft = try plan(regularSpec(["USA": "34.99"]), catalog.snapshot())
        #expect(draft.items.isEmpty)
        #expect(draft.excluded == [.regular(subscriptionId: "s", territory: "USA", planType: .upfront)])
        #expect(draft.verdicts("I8").map(\.severity) == [.block(.cell)])
    }

    @Test func checkOnlyColumnsProduceDiffsWithoutItems() async throws {
        let (table, _) = try await SyntheticImport.importedTable()
        var catalog = SyntheticCatalog.fromSyntheticTable(table)
        catalog.setRegular(SyntheticImport.alpha, "USA", d("44.99"), start: today.adding(days: -1))
        let spec = PlanSpec.importTable(ImportPlanSpec(table: table, writeColumns: [], filter: PlanFilter(productAscIds: [SyntheticImport.alpha]),
                                                       startDate: nil, preserveCurrentPrice: nil, canary: false))
        let draft = try plan(spec, catalog.snapshot(), config: SyntheticCatalog.config(mapping: SyntheticImport.mapping()))
        #expect(draft.items.isEmpty)
        let usa = try #require(table.row(for: "USA")?.values["C"]?.amount)
        #expect(draft.checkDiffs == [CheckDiff(column: "C", cell: .regular(subscriptionId: SyntheticImport.alpha, territory: "USA", planType: .upfront),
                                               imported: usa, snapped: usa, live: d("44.99"))]
                + draft.checkDiffs.filter { $0.column == "D" })
        #expect(draft.checkDiffs.filter { $0.column == "D" }.count == 175)
        #expect(draft.checkDiffs.filter { $0.column == "D" }.allSatisfy { $0.live == nil })
    }

    @Test func estimateHashesAndConfirmationLevel() async throws {
        let (table, _) = try await SyntheticImport.importedTable()
        let snapshot = SyntheticCatalog.fromSyntheticTable(table).snapshot()
        let spec = PlanSpec.importTable(ImportPlanSpec(table: table, writeColumns: ["D", "F", "H"], filter: PlanFilter(),
                                                       startDate: today.adding(days: 7), preserveCurrentPrice: nil, canary: false))
        let rate = RateLimitSnapshot.parse("user-hour-lim:3500;user-hour-rem:3500;", at: Date())
        let context = PlanningContext(snapshot: snapshot, config: SyntheticCatalog.config(isProduction: true, mapping: SyntheticImport.mapping()),
                                      today: today, rateLimit: rate)
        let planner = Planner(policy: PolicyEngine())
        let a = try planner.plan(spec, context: context)
        let b = try planner.plan(spec, context: context)
        #expect(a.estimate == Estimate(requests: 525 + 1 + 3 + 2 * 3, minutes: 10))
        #expect(a.planHash == b.planHash)
        #expect(a.planHash.count == 64)
        #expect(a.verdictHash == PolicyEngine.hash(a.verdicts))
        #expect(a.confirmationLevel == .c1)
        #expect(a.baseSyncId == snapshot.syncId)
        let narrower = try planner.plan(.importTable(ImportPlanSpec(table: table, writeColumns: ["D"], filter: PlanFilter(), startDate: today.adding(days: 7),
                                                                    preserveCurrentPrice: nil, canary: false)), context: context)
        #expect(narrower.planHash != a.planHash)
    }

    @Test func goldenSmallPlan() throws {
        let draft = try plan(introSpec(.percentOfRegular(d("0.8")), start: today.adding(days: 7), territories: ["USA", "DEU"]),
                             yearly(.approved).snapshot())
        let json = try JSONCoding.string(draft.items)
        let golden = try String(decoding: RepoFiles.fixtureData("plans/golden-small-intro-plan.json"), as: UTF8.self)
        #expect(json == golden.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@Suite struct PlanPersistenceTests {
    struct Fixture {
        let database: WorkspaceDatabase
        let store: PlanStore
        let audit: AuditLog
        let persistence: PlanPersistence

        init() throws {
            database = try WorkspaceDatabase.inMemory()
            store = PlanStore(database: database)
            audit = AuditLog(database: database, actor: { "owner" }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
            let ids = IdSequence()
            persistence = PlanPersistence(store: store, audit: audit, appBuild: "1.0 (42)",
                                          now: { Date(timeIntervalSince1970: 1_800_000_000) }, makeId: { ids.next() })
        }
    }

    final class IdSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> String { lock.withLock { n += 1; return "plan-\(n)" } }
    }

    func draft() throws -> PlanDraft {
        try plan(introSpec(.percentOfRegular(d("0.8")), start: today.adding(days: 7), territories: ["USA", "DEU"]), yearly(.approved).snapshot())
    }

    @Test func saveDraftStoresPlanItemsAndAudit() throws {
        let f = try Fixture()
        let draft = try draft()
        let id = try f.persistence.saveDraft(draft, binding: PlanBinding(config: SyntheticCatalog.config()), reason: "spring intro", replanOf: nil)
        let stored = try #require(try f.store.plan(id: id))
        #expect(stored.state == .draft)
        #expect(stored.origin == .intro)
        #expect(stored.planHash == draft.planHash)
        #expect(stored.appBuild == "1.0 (42)")
        #expect(stored.estimateRequests == draft.estimate.requests)
        #expect(try JSONCoding.decode(PlanSpec.self, from: stored.specJSON) == draft.spec)
        #expect(try f.store.items(planId: id).map(\.item) == draft.items)
        let events = try f.audit.events(after: 0, limit: 10)
        #expect(events.map(\.type) == [.planCreated])
        #expect(events[0].refs == ["plan": id])
        #expect(events[0].payloadJSON.contains("\"planHash\":\"\(draft.planHash)\""))
    }

    @Test func cancelClosesDraftAndAudits() throws {
        let f = try Fixture()
        let id = try f.persistence.saveDraft(try draft(), binding: PlanBinding(config: SyntheticCatalog.config()), reason: nil, replanOf: nil)
        try f.persistence.cancel(planId: id)
        let stored = try #require(try f.store.plan(id: id))
        #expect(stored.state == .cancelled)
        #expect(stored.endReason == .cancelledByUser)
        #expect(try f.audit.events(after: 0, limit: 10).map(\.type) == [.planCreated, .planStateChanged])
        #expect(throws: PlanPersistenceError.notADraft(.cancelled)) { try f.persistence.cancel(planId: id) }
        #expect(throws: PlanPersistenceError.notFound("nope")) { try f.persistence.cancel(planId: "nope") }
    }

    @Test func replanCreatesNewPlanWithReplanOf() throws {
        let f = try Fixture()
        let first = try f.persistence.saveDraft(try draft(), binding: PlanBinding(config: SyntheticCatalog.config()), reason: "v1", replanOf: nil)
        let second = try f.persistence.replan(planId: first, with: try draft(), binding: PlanBinding(config: SyntheticCatalog.config()), reason: nil)
        #expect(second != first)
        #expect(try f.store.plan(id: second)?.replanOf == first)
        #expect(try f.store.plan(id: second)?.reason == "v1")
        #expect(try f.store.plan(id: first)?.state == .cancelled)
        #expect(try f.store.plan(id: first)?.endReason == .replanned)
        let events = try f.audit.events(after: 0, limit: 10)
        #expect(events.map(\.type) == [.planCreated, .planCreated, .planStateChanged])
        #expect(events[1].refs == ["plan": second])
        #expect(events[1].payloadJSON.contains("\"replanOf\":\"\(first)\""))
    }

    /// Plan and items become Effective the way the M2 Reconciler leaves them.
    func markEffective(_ store: PlanStore, planId: String) throws {
        guard var plan = try store.plan(id: planId) else {
            Issue.record("missing plan \(planId)")
            return
        }
        plan.state = .effective
        let items = try store.items(planId: planId)
        try store.database.writer.write { db in
            try store.update(plan, in: db)
            for var item in items {
                item.state = .effective
                try store.update(item, in: db)
            }
        }
    }

    @Test func effectiveCanaryIntroPlansUnlockTheirProducts() throws {
        let f = try Fixture()
        var catalog = yearly(.approved)
        catalog.addIntro("s", "USA", price: d("25.99"))
        let snapshot = catalog.snapshot()
        let binding = PlanBinding(config: SyntheticCatalog.config())
        let canary = try plan(introSpec(.percentOfRegular(d("0.8")), territories: ["USA"], canary: true), snapshot)
        #expect(canary.ops == [.patchEnd, .post])
        let canaryId = try f.persistence.saveDraft(canary, binding: binding, reason: "canary", replanOf: nil)
        let plainId = try f.persistence.saveDraft(try plan(introSpec(.percentOfRegular(d("0.8")), territories: ["USA"]), snapshot),
                                                  binding: binding, reason: nil, replanOf: nil)
        // Drafts never unlock anything.
        #expect(try LiveIntroCanaries.unlockedProducts(store: f.store).isEmpty)
        // An Effective plan that is not a CANARY does not unlock either.
        try markEffective(f.store, planId: plainId)
        #expect(try LiveIntroCanaries.unlockedProducts(store: f.store).isEmpty)
        // An Effective CANARY with an Effective PATCH_END unlocks its product.
        try markEffective(f.store, planId: canaryId)
        #expect(try LiveIntroCanaries.unlockedProducts(store: f.store) == ["s"])
    }
}
