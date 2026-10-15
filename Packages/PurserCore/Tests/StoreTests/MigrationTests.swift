import Foundation
import GRDB
import Testing
@testable import Store
import PurserTestSupport

@Suite struct MigrationTests {
    @Test func migrationsCreateEveryTable() throws {
        let database = try WorkspaceDatabase.inMemory()
        let tables = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name")
        }
        #expect(tables == ["audit_event", "finding", "item", "metadata_version", "observation", "offer_code_registry", "plan",
                           "price_point", "price_point_generation", "product", "subscription_group", "sync_run", "territory",
                           "workspace"])
        let indexes = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        }
        #expect(indexes == ["item_asc_id", "item_natural_key", "metadata_version_owner", "observation_cell", "observation_identity",
                            "price_point_lookup"])
        let triggers = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
        }
        #expect(triggers == ["audit_no_delete", "audit_no_update", "price_point_generation_delete", "price_point_generation_insert",
                             "price_point_generation_update"])
    }

    @Test func migrationV2UpgradesADatabaseMadeByV1() throws {
        let queue = try DatabaseQueue()
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1") { db in try db.execute(sql: Migrations.v1) }
        try v1Only.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO sync_run (trigger, status, started_at) VALUES ('manual', 'complete', '2026-10-09T12:00:00.000Z')")
        }
        try Migrations.migrator.migrate(queue)
        #expect(try queue.read { db in try Migrations.migrator.appliedMigrations(db) } == ["v1", "v2", "v3"])
        try queue.write { db in
            try db.execute(sql: "INSERT INTO subscription_group (asc_id, reference_name, first_sync, last_sync) VALUES ('7000000001', 'Fruit Premium', 1, 1)")
            try db.execute(sql: "INSERT INTO metadata_version (asc_id, owner_key, number, state, last_sync) VALUES ('sver-1', 'S|6500000001', 1, 'APPROVED', 1)")
        }
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_run") } == 1)
    }

    @Test func migrationV3StartsTheGenerationOfAV2Database() throws {
        let queue = try DatabaseQueue()
        var throughV2 = DatabaseMigrator()
        throughV2.registerMigration("v1") { db in try db.execute(sql: Migrations.v1) }
        throughV2.registerMigration("v2") { db in try db.execute(sql: Migrations.v2) }
        try throughV2.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO price_point (id, product_asc_id, territory, plan_type, customer_price, proceeds, fetched_at)
                VALUES ('pp-1', '6500000001', 'USA', 'UPFRONT', '9.99', '7.0', '2026-10-09T12:00:00.000Z')
                """)
        }
        try Migrations.migrator.migrate(queue)
        #expect(try queue.read { db in try Int64.fetchOne(db, sql: "SELECT value FROM price_point_generation") } == 0)
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM price_point") } == 1)
    }

    @Test func everyChangeOfAPricePointBumpsTheGeneration() throws {
        let database = try WorkspaceDatabase.inMemory()
        func generation() throws -> Int64? {
            try database.writer.read { db in try Int64.fetchOne(db, sql: "SELECT value FROM price_point_generation") }
        }
        #expect(try generation() == 0)
        try database.writer.write { db in
            for id in ["pp-1", "pp-2"] {
                try db.execute(sql: """
                    INSERT INTO price_point (id, product_asc_id, territory, plan_type, customer_price, proceeds, fetched_at)
                    VALUES (?, '6500000001', 'USA', 'UPFRONT', '9.99', NULL, '2026-10-09T12:00:00.000Z')
                    """, arguments: [id])
            }
        }
        #expect(try generation() == 2)
        try database.writer.write { db in try db.execute(sql: "UPDATE price_point SET customer_price = '10.99' WHERE id = 'pp-1'") }
        #expect(try generation() == 3)
        try database.writer.write { db in try db.execute(sql: "DELETE FROM price_point") }
        #expect(try generation() == 5)
        // An unrelated write leaves it alone.
        try database.writer.write { db in try db.execute(sql: "INSERT INTO territory (code, currency) VALUES ('CZE', 'CZK')") }
        #expect(try generation() == 5)
    }

    @Test func auditEventRejectsUpdateAndDelete() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO audit_event (seq, ts, type, actor, refs_json, payload_json, prev_hash, hash)
                VALUES (1, '2026-10-09T12:00:00.000Z', 'signIn', 'owner', '{}', '{}', 'p', 'h')
                """)
        }
        let update = #expect(throws: DatabaseError.self) {
            try database.writer.write { db in try db.execute(sql: "UPDATE audit_event SET actor = 'mallory' WHERE seq = 1") }
        }
        #expect(update?.message == "audit_event is append-only")
        let delete = #expect(throws: DatabaseError.self) {
            try database.writer.write { db in try db.execute(sql: "DELETE FROM audit_event WHERE seq = 1") }
        }
        #expect(delete?.message == "audit_event is append-only")
        let count = try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_event") }
        #expect(count == 1)
    }

    @Test func fileDatabaseUsesWALAndSurvivesReopen() throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("ws-test", isDirectory: true)
        do {
            let database = try WorkspaceDatabase.open(at: directory)
            let mode = try database.writer.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
            #expect(mode == "wal")
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO territory (code, currency) VALUES ('CZE', 'CZK')")
            }
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("purser.sqlite").path))
        let reopened = try WorkspaceDatabase.open(at: directory)
        let currency = try reopened.writer.read { db in try String.fetchOne(db, sql: "SELECT currency FROM territory WHERE code = 'CZE'") }
        #expect(currency == "CZK")
    }

    @Test func fileDatabaseWaitsTenSecondsWhenBusy() throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("ws-busy", isDirectory: true)
        let database = try WorkspaceDatabase.open(at: directory)
        guard case let .timeout(seconds) = database.writer.configuration.busyMode else {
            Issue.record("busyMode must be .timeout(10) because the app and the login item share the file")
            return
        }
        #expect(seconds == 10)
    }

    @Test func foreignKeysAreEnforced() throws {
        let database = try WorkspaceDatabase.inMemory()
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO product (asc_id, product_id, kind, info_json, first_sync, last_sync) VALUES ('1', 'p', 'SUB', '{}', 99, 99)")
            }
        }
    }
}
