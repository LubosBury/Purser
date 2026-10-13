import CryptoKit
import Foundation
import GRDB
import Domain
import Store
import Audit
import Catalog

/// Runs invariants after a sync and stores INVARIANT findings (dedupe by fingerprint).
public struct InvariantRunner: Sendable {
    private let engine: PolicyEngine
    private let catalog: CatalogStore
    private let database: WorkspaceDatabase
    private let audit: AuditLog

    public init(engine: PolicyEngine, catalog: CatalogStore, database: WorkspaceDatabase, audit: AuditLog) {
        self.engine = engine; self.catalog = catalog; self.database = database; self.audit = audit
    }

    /// fingerprint = sha256hex("type|rule|cell storage key|message"); CatalogStore.upsertFinding uses the same formula.
    public static func fingerprint(type: FindingType, rule: RuleID?, cell: CellKey, message: String) -> String {
        let input = "\(type.rawValue)|\(rule?.rawValue ?? "")|\(cell.storageKey)|\(message)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns only findings that did not exist before (same fingerprint = same finding, lastSync is bumped).
    public func run(snapshot: CatalogSnapshot, today: CalendarDate) throws -> [FindingRecord] {
        let verdicts = engine.invariants(snapshot, today: today)
        return try database.writer.write { db in
            var created: [FindingRecord] = []
            for verdict in verdicts {
                guard let cell = verdict.cell else { continue }
                guard let record = try catalog.upsertFinding(type: .invariant, rule: verdict.rule, cell: cell,
                                                             message: verdict.message, syncId: snapshot.syncId, in: db) else { continue }
                created.append(record)
                try audit.append(.findingRaised,
                                 refs: ["syncId": String(snapshot.syncId), "finding": String(record.id),
                                        "rule": verdict.rule.rawValue, "cell": cell.storageKey],
                                 payload: FindingRaisedPayload(type: FindingType.invariant.rawValue, rule: verdict.rule.rawValue,
                                                               cell: cell.storageKey, message: verdict.message, syncId: snapshot.syncId),
                                 in: db)
            }
            return created
        }
    }
}

struct FindingRaisedPayload: Encodable {
    var type: String
    var rule: String
    var cell: String
    var message: String
    var syncId: Int64
}
