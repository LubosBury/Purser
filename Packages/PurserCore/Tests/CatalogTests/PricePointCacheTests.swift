import Foundation
import GRDB
import Testing
@testable import Catalog
import Domain
import Store
import PurserTestSupport

/// Snapshots share one price point index until a price point changes (PricePointCache).
@Suite struct PricePointCacheTests {
    @Test func snapshotsShareTheIndexUntilAPricePointChanges() throws {
        let database = try WorkspaceDatabase.inMemory()
        try seedSync(database)
        try insert(database, [("pp-1", "USA", "UPFRONT", "9.99"), ("pp-2", "USA", "UPFRONT", "12.99")])
        let store = CatalogStore(database: database)

        let first = try #require(try store.latestSnapshot())
        let second = try #require(try store.latestSnapshot())
        #expect(second.pricePoints.sharesStorage(with: first.pricePoints))
        // A copy of the store (as the session hands it to a detached task) shares it as well.
        let copy = store
        #expect(try #require(try copy.latestSnapshot()).pricePoints.sharesStorage(with: first.pricePoints))

        try database.writer.write { db in try db.execute(sql: "UPDATE price_point SET customer_price = '10.99' WHERE id = 'pp-1'") }
        let changed = try #require(try store.latestSnapshot())
        #expect(!changed.pricePoints.sharesStorage(with: first.pricePoints))
        #expect(changed.pricePoints.point(id: "pp-1")?.customerPrice == Decimal(string: "10.99"))
        #expect(first.pricePoints.point(id: "pp-1")?.customerPrice == Decimal(string: "9.99"))
    }

    @Test func aChangeWrittenByAnotherConnectionIsSeen() throws {
        // The login item writes the same file through its own connection.
        let directory = try makeTemporaryDirectory().appendingPathComponent("ws-cache", isDirectory: true)
        let app = try WorkspaceDatabase.open(at: directory)
        let loginItem = try WorkspaceDatabase.open(at: directory)
        try seedSync(app)
        try insert(app, [("pp-1", "USA", "UPFRONT", "9.99")])
        let store = CatalogStore(database: app)
        let before = try #require(try store.latestSnapshot())
        #expect(before.pricePoints.points(productAscId: "6500000001", territory: "USA", planType: .upfront).count == 1)

        try insert(loginItem, [("pp-2", "USA", "UPFRONT", "12.99")])
        let after = try #require(try store.latestSnapshot())
        #expect(after.pricePoints.points(productAscId: "6500000001", territory: "USA", planType: .upfront).map(\.id) == ["pp-1", "pp-2"])
    }

    @Test func snapshotsTakenAtOnceBuildTheIndexOnce() throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("ws-concurrent", isDirectory: true)
        let database = try WorkspaceDatabase.open(at: directory)
        try seedSync(database)
        try insert(database, (0..<2_000).map { ("pp-\($0)", "USA", "UPFRONT", "\($0).99") })
        let store = CatalogStore(database: database)
        let snapshots = SnapshotList()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let snapshot = try? store.latestSnapshot()
            snapshots.append(snapshot)
        }
        let all = snapshots.values.compactMap { $0 }
        #expect(all.count == 4)
        #expect(all.allSatisfy { $0.pricePoints.sharesStorage(with: all[0].pricePoints) })
    }

    @Test func withoutTheCounterRowEverySnapshotReadsThePricePoints() throws {
        let database = try WorkspaceDatabase.inMemory()
        try seedSync(database)
        try insert(database, [("pp-1", "USA", "UPFRONT", "9.99")])
        try database.writer.write { db in try db.execute(sql: "DELETE FROM price_point_generation") }
        let store = CatalogStore(database: database)
        let first = try #require(try store.latestSnapshot())
        try insert(database, [("pp-2", "USA", "UPFRONT", "12.99")])
        let second = try #require(try store.latestSnapshot())
        #expect(!second.pricePoints.sharesStorage(with: first.pricePoints))
        #expect(second.pricePoints.point(id: "pp-2") != nil)
    }

    @Test func rowsAreGroupedAsBefore() throws {
        // The old index grouped decoded points, so a lower-case territory and an unknown plan type joined their ladders.
        let database = try WorkspaceDatabase.inMemory()
        try seedSync(database)
        try insert(database, [("pp-1", "USA", "UPFRONT", "9.99"), ("pp-2", "usa", "UPFRONT", "4.99"), ("pp-3", "USA", nil, "1.99"),
                              ("pp-4", "USA", "WEEKLY", "2.99"), ("pp-5", "USA", "UPFRONT", "not a price")])
        let index = try #require(try CatalogStore(database: database).latestSnapshot()).pricePoints
        #expect(index.points(productAscId: "6500000001", territory: "USA", planType: .upfront).map(\.id) == ["pp-5", "pp-2", "pp-1"])
        #expect(index.points(productAscId: "6500000001", territory: "USA", planType: nil).map(\.id) == ["pp-3", "pp-4"])
        #expect(index.point(id: "pp-5")?.customerPrice == 0)
        #expect(index.point(id: "pp-2")?.proceeds == Decimal(string: "0.7"))
    }

    // MARK: - Helpers

    private func seedSync(_ database: WorkspaceDatabase) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sync_run (trigger, status, started_at, finished_at) VALUES ('manual', 'complete', ?, ?)
                """, arguments: ["2026-10-15T12:00:00.000Z", "2026-10-15T12:01:00.000Z"])
        }
    }

    private func insert(_ database: WorkspaceDatabase, _ rows: [(id: String, territory: String, planType: String?, price: String)]) throws {
        try database.writer.write { db in
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO price_point (id, product_asc_id, territory, plan_type, customer_price, proceeds, fetched_at)
                    VALUES (?, '6500000001', ?, ?, ?, '0.7', '2026-10-15T12:00:00.000Z')
                    """, arguments: [row.id, row.territory, row.planType, row.price])
            }
        }
    }
}

private final class SnapshotList: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CatalogSnapshot?] = []
    var values: [CatalogSnapshot?] { lock.withLock { stored } }
    func append(_ snapshot: CatalogSnapshot?) { lock.withLock { stored.append(snapshot) } }
}
