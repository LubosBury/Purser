import Foundation
import GRDB
import Domain

/// The single `workspace` row of a workspace database.
public struct WorkspaceConfigStore: Sendable {
    private let database: WorkspaceDatabase

    public init(database: WorkspaceDatabase) {
        self.database = database
    }

    public func load() throws -> WorkspaceConfig? {
        try database.writer.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT config_json FROM workspace LIMIT 1") else { return nil }
            return try JSONCoding.decode(WorkspaceConfig.self, from: json)
        }
    }

    /// Inserts or replaces the config. Refuses a config whose id differs from the stored one (D3).
    /// Callers log `configChanged` in the same transaction.
    public func save(_ config: WorkspaceConfig, at date: Date, in db: Database) throws {
        if let stored = try String.fetchOne(db, sql: "SELECT id FROM workspace LIMIT 1"),
           let storedId = UUID(uuidString: stored), storedId != config.id {
            throw StoreError.workspaceMismatch(stored: storedId, attempted: config.id)
        }
        try db.execute(
            sql: """
            INSERT INTO workspace (id, config_json, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET config_json = excluded.config_json, updated_at = excluded.updated_at
            """,
            arguments: [config.id.uuidString, try JSONCoding.string(config), Timestamp.string(date)])
    }
}
