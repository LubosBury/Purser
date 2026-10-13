import Foundation
import Testing
import Domain
import Store
import Audit
import Catalog
@testable import Policy
import PurserTestSupport

/// One product in 175 territories, regular 29.99 everywhere; a live PUF intro priced 31.99 (above regular) in the first
/// 148 territories (sorted by code) and 23.99 in the remaining 27.
func goldenI4Catalog() throws -> SyntheticCatalog {
    let codes = Array(Set(try RepoFiles.territoryNames().storefronts.values)).sorted()
    var catalog = SyntheticCatalog()
    catalog.addSubscription("sub-golden", prices: Dictionary(uniqueKeysWithValues: codes.map { ($0, d("29.99")) }))
    for (index, code) in codes.enumerated() {
        catalog.addIntro("sub-golden", code, price: index < 148 ? d("31.99") : d("23.99"))
    }
    return catalog
}

@Suite struct FindingsTests {
    struct Env {
        let database: WorkspaceDatabase
        let audit: AuditLog
        let catalog: CatalogStore
        let runner: InvariantRunner
        init() throws {
            database = try WorkspaceDatabase.inMemory()
            audit = AuditLog(database: database, actor: { "owner" }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
            catalog = CatalogStore(database: database)
            runner = InvariantRunner(engine: PolicyEngine(), catalog: catalog, database: database, audit: audit)
        }
    }

    @Test func goldenSnapshotGivesOneGroupOf148I4Findings() throws {
        let env = try Env()
        let created = try env.runner.run(snapshot: try goldenI4Catalog().snapshot(), today: today)
        #expect(created.count == 148)
        #expect(created.allSatisfy { $0.type == .invariant && $0.rule == "I4" })
        let groups = FindingGroups.group(try env.catalog.findings(includeAcked: false))
        #expect(groups.count == 1)
        #expect(groups[0].rule == "I4")
        #expect(groups[0].productAscId == "sub-golden")
        #expect(groups[0].cellCount == 148)
        #expect(groups[0].findings[0].message == "The intro 31.99 USD is not cheaper than the regular price 29.99 USD.")
        #expect(try env.runner.run(snapshot: try goldenI4Catalog().snapshot(), today: today.adding(days: 1)).isEmpty)
        #expect(try env.catalog.findings(includeAcked: true).count == 148)
        #expect(try env.audit.events(after: 0, limit: 500).filter { $0.type == .findingRaised }.count == 148)
    }

    @Test func groupingSeparatesRulesAndProducts() throws {
        func verdict(_ rule: RuleID, _ sub: String, _ t: TerritoryCode) -> Verdict {
            Verdict(rule: rule, severity: .block(.cell), cell: .intro(subscriptionId: sub, territory: t, planType: .upfront), message: "m \(rule)")
        }
        let records = try FindingFactory.records([verdict("I4", "a", "USA"), verdict("I5", "a", "USA"), verdict("I4", "b", "DEU"), verdict("I4", "a", "CZE")])
        let groups = FindingGroups.group(records)
        #expect(groups.map(\.id) == ["INVARIANT|I4|a", "INVARIANT|I4|b", "INVARIANT|I5|a"])
        #expect(groups[0].findingIds == [4, 1])
        #expect(groups[0].territories == ["USA", "CZE"])
    }

    @Test func ackNeedsReasonAndIsAudited() throws {
        let env = try Env()
        let created = try env.runner.run(snapshot: try goldenI4Catalog().snapshot(), today: today)
        let acknowledger = FindingAcknowledger(catalog: env.catalog, audit: env.audit, now: { Date(timeIntervalSince1970: 1_800_000_100) })
        #expect(throws: FindingAckError.reasonTooShort(minimum: 5)) { try acknowledger.ack(findingIds: [created[0].id], reason: "  ok ") }
        try acknowledger.ack(findingIds: created.prefix(2).map(\.id), reason: "old intro, ends next week")
        #expect(try env.catalog.findings(includeAcked: false).count == 146)
        let acked = try env.catalog.findings(includeAcked: true).filter { $0.ackReason != nil }
        #expect(acked.map(\.ackReason) == ["old intro, ends next week", "old intro, ends next week"])
        #expect(try env.audit.events(after: 0, limit: 500).filter { $0.type == .findingAcked }.count == 2)
    }

    @Test func postSyncChecksSkipFailedSyncs() throws {
        let env = try Env()
        let checks = PostSyncChecks(runner: env.runner, catalog: env.catalog, now: { Date() })
        #expect(try checks.afterSync(status: .failed).isEmpty)
        #expect(try checks.afterSync(status: .complete).isEmpty)
    }
}
