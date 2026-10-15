import CryptoKit
import Foundation
import GRDB
import Testing
import Catalog
import Domain
import Store
import PurserTestSupport

@Suite struct CatalogStoreTests {
    private let cell = CellKey.regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront)

    @Test func noSnapshotBeforeTheFirstSync() throws {
        #expect(try CatalogStore(database: try WorkspaceDatabase.inMemory()).latestSnapshot() == nil)
    }

    @Test func upsertFindingDedupesByFingerprint() throws {
        let database = try WorkspaceDatabase.inMemory()
        let store = CatalogStore(database: database)
        let first = try database.writer.write { db in
            try store.upsertFinding(type: .external, rule: nil, cell: cell, message: "changed", syncId: 1, in: db)
        }
        #expect(first?.firstSync == 1)
        let again = try database.writer.write { db in
            try store.upsertFinding(type: .external, rule: nil, cell: cell, message: "changed", syncId: 2, in: db)
        }
        #expect(again == nil)
        let other = try database.writer.write { db in
            try store.upsertFinding(type: .invariant, rule: "I4", cell: cell, message: "changed", syncId: 2, in: db)
        }
        #expect(other?.rule == "I4")
        let all = try store.findings(includeAcked: true)
        #expect(all.count == 2)
        #expect(all[0].lastSync == 2)
        #expect(all[0].firstSync == 1)
    }

    @Test func aDiscriminatorTellsTwoFindingsWithTheSameMessageApart() throws {
        let database = try WorkspaceDatabase.inMemory()
        let store = CatalogStore(database: database)
        let findings = try database.writer.write { db in
            try ["hash-a", "hash-b", "hash-a"].map {
                try store.upsertFinding(type: .external, rule: nil, cell: cell, message: "changed", discriminator: $0, syncId: 1, in: db)
            }
        }
        #expect(findings.map { $0 != nil } == [true, true, false])
        // Without a discriminator the fingerprint keeps its formula (the one InvariantRunner uses as well).
        let plain = try #require(try database.writer.write { db in
            try store.upsertFinding(type: .external, rule: nil, cell: cell, message: "changed", syncId: 1, in: db)
        })
        let formula = SHA256.hash(data: Data("EXTERNAL||\(cell.storageKey)|changed".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(plain.fingerprint == formula)
    }

    @Test func ackHidesAFindingFromTheOpenList() throws {
        let database = try WorkspaceDatabase.inMemory()
        let store = CatalogStore(database: database)
        let finding = try #require(try database.writer.write { db in
            try store.upsertFinding(type: .external, rule: nil, cell: cell, message: "changed", syncId: 1, in: db)
        })
        try store.ack(findingId: finding.id, reason: "Changed by hand in ASC on purpose", at: Sample.fixedNow)
        #expect(try store.findings(includeAcked: false).isEmpty)
        let acked = try #require(try store.findings(includeAcked: true).first)
        #expect(acked.ackReason == "Changed by hand in ASC on purpose")
        #expect(acked.ackAt == Sample.fixedNow)
    }
}
