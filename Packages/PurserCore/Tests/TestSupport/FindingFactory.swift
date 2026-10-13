import Foundation
import Domain
import Store
import Catalog

/// Stores verdicts as INVARIANT findings through CatalogStore.upsertFinding in an in-memory database,
/// so ids and fingerprints are produced exactly as in production code.
public enum FindingFactory {
    public static func records(_ verdicts: [Verdict], syncId: Int64 = 1) throws -> [FindingRecord] {
        let database = try WorkspaceDatabase.inMemory()
        let catalog = CatalogStore(database: database)
        return try database.writer.write { db in
            try verdicts.compactMap { verdict in
                guard let cell = verdict.cell else { return nil }
                return try catalog.upsertFinding(type: .invariant, rule: verdict.rule, cell: cell, message: verdict.message, syncId: syncId, in: db)
            }
        }
    }
}
