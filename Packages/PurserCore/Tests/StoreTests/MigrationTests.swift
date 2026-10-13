import Foundation
import GRDB
import Testing
import Store
import PurserTestSupport

@Suite struct MigrationTests {
    @Test func migrationV1CreatesEveryTable() throws {
        let database = try WorkspaceDatabase.inMemory()
        let tables = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name")
        }
        #expect(tables == ["audit_event", "finding", "item", "observation", "offer_code_registry", "plan",
                           "price_point", "product", "sync_run", "territory", "workspace"])
        let indexes = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        }
        #expect(indexes == ["item_asc_id", "item_natural_key", "observation_cell", "observation_identity", "price_point_lookup"])
        let triggers = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
        }
        #expect(triggers == ["audit_no_delete", "audit_no_update"])
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
