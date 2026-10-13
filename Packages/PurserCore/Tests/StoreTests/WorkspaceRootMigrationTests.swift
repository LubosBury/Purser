import Foundation
import Testing
import GRDB
import Store

@Suite struct WorkspaceRootMigrationTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("purser-migration-\(UUID().uuidString)", isDirectory: true)
    }

    /// Creates two workspaces with one row each in the legacy root; databases are closed on return.
    func seedLegacy(_ root: URL) throws -> [WorkspaceEntry] {
        let registry = WorkspaceRegistry(root: root)
        let alpha = try registry.create(name: "Alpha", colorHex: "#112233")
        let beta = try registry.create(name: "Beta", colorHex: "#445566")
        for entry in [alpha, beta] {
            let database = try WorkspaceDatabase.open(at: registry.directory(for: entry))
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO workspace (id, config_json, updated_at) VALUES (?, ?, ?)",
                               arguments: [entry.id.uuidString, "{}", "2030-03-01T00:00:00Z"])
            }
        }
        return try registry.list()
    }

    func workspaceRowCount(root: URL, entry: WorkspaceEntry) throws -> Int {
        let registry = WorkspaceRegistry(root: root)
        let database = try WorkspaceDatabase.open(at: registry.directory(for: entry))
        return try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspace") ?? 0 }
    }

    @Test func movesRegistryAndDatabasesAndLeavesMarker() throws {
        let legacy = tempRoot(), group = tempRoot()
        let entries = try seedLegacy(legacy)
        #expect(try WorkspaceRootMigration.migrate(from: legacy, to: group) == .migrated(count: 2))
        #expect(try WorkspaceRegistry(root: group).list() == entries)
        for entry in entries { #expect(try workspaceRowCount(root: group, entry: entry) == 1) }
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent(WorkspaceRootMigration.registryFileName).path))
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(WorkspaceRootMigration.markerFileName).path))
        #expect(try WorkspaceRootMigration.migrate(from: legacy, to: group) == .alreadyMigrated)
    }

    @Test func resumesAfterAnInterruptedRun() throws {
        let legacy = tempRoot(), group = tempRoot()
        let entries = try seedLegacy(legacy)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: legacy.appendingPathComponent(entries[0].directoryName),
                                         to: group.appendingPathComponent(entries[0].directoryName))
        #expect(try WorkspaceRootMigration.migrate(from: legacy, to: group) == .migrated(count: 2))
        for entry in entries { #expect(try workspaceRowCount(root: group, entry: entry) == 1) }
    }

    @Test func refusesWhenBothRootsHaveARegistry() throws {
        let legacy = tempRoot(), group = tempRoot()
        _ = try seedLegacy(legacy)
        _ = try WorkspaceRegistry(root: group).create(name: "Other", colorHex: "#000000")
        #expect(throws: WorkspaceRootMigrationError.self) {
            try WorkspaceRootMigration.migrate(from: legacy, to: group)
        }
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(WorkspaceRootMigration.registryFileName).path))
    }

    @Test func emptyLegacyRootHasNothingToMigrate() throws {
        #expect(try WorkspaceRootMigration.migrate(from: tempRoot(), to: tempRoot()) == .nothingToMigrate)
    }
}
