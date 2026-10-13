import Foundation
import GRDB
import Domain

public struct StoredPlan: Hashable, Sendable {
    public var id: String
    public var origin: PlanOrigin
    public var specJSON: String
    public var importJSON: String?
    public var binding: PlanBinding
    public var baseSyncId: Int64
    public var state: PlanState
    public var pauseReason: PauseReason?
    public var endReason: PlanEndReason?
    public var planHash: String
    public var verdictHash: String
    public var verdicts: [Verdict]
    public var excluded: [CellKey]
    public var productStates: [String: ProductState]
    public var reason: String?
    public var confirmationLevel: ConfirmationLevel
    public var appBuild: String
    public var estimateRequests: Int
    public var estimateMinutes: Int
    public var replanOf: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var heartbeatAt: Date?

    public init(id: String, origin: PlanOrigin, specJSON: String, importJSON: String?, binding: PlanBinding, baseSyncId: Int64,
                state: PlanState, pauseReason: PauseReason?, endReason: PlanEndReason?, planHash: String, verdictHash: String,
                verdicts: [Verdict], excluded: [CellKey], productStates: [String: ProductState], reason: String?,
                confirmationLevel: ConfirmationLevel, appBuild: String, estimateRequests: Int, estimateMinutes: Int,
                replanOf: String?, createdAt: Date, updatedAt: Date, heartbeatAt: Date?) {
        self.id = id; self.origin = origin; self.specJSON = specJSON; self.importJSON = importJSON; self.binding = binding
        self.baseSyncId = baseSyncId; self.state = state; self.pauseReason = pauseReason; self.endReason = endReason
        self.planHash = planHash; self.verdictHash = verdictHash; self.verdicts = verdicts; self.excluded = excluded
        self.productStates = productStates; self.reason = reason; self.confirmationLevel = confirmationLevel
        self.appBuild = appBuild; self.estimateRequests = estimateRequests; self.estimateMinutes = estimateMinutes
        self.replanOf = replanOf; self.createdAt = createdAt; self.updatedAt = updatedAt; self.heartbeatAt = heartbeatAt
    }
}

public struct StoredItem: Hashable, Sendable {
    public var planId: String
    public var item: PlannedItem
    public var state: ItemState
    public var attempts: Int
    public var ascId: String?
    public var errorJSON: String?
    public var verifiedAt: Date?
    public var effectiveAt: Date?
    public var supersededBy: String?

    public init(planId: String, item: PlannedItem, state: ItemState, attempts: Int, ascId: String?, errorJSON: String?,
                verifiedAt: Date?, effectiveAt: Date?, supersededBy: String?) {
        self.planId = planId; self.item = item; self.state = state; self.attempts = attempts; self.ascId = ascId
        self.errorJSON = errorJSON; self.verifiedAt = verifiedAt; self.effectiveAt = effectiveAt; self.supersededBy = supersededBy
    }
}

public struct PlanStore: Sendable {
    /// Public so callers can combine `update(_:in:)` with an audit event in one transaction.
    public let database: WorkspaceDatabase

    public init(database: WorkspaceDatabase) {
        self.database = database
    }

    /// Stores the plan and its items (state pending, 0 attempts) in one transaction.
    public func insert(_ plan: StoredPlan, items: [PlannedItem]) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO plan (id, origin, spec_json, import_json, binding_json, base_sync, state, pause_reason, end_reason,
                  plan_hash, verdict_hash, verdicts_json, excluded_json, product_states_json, reason, confirmation_level,
                  app_build, estimate_requests, estimate_minutes, replan_of, created_at, updated_at, heartbeat_at)
                VALUES (:id, :origin, :spec_json, :import_json, :binding_json, :base_sync, :state, :pause_reason, :end_reason,
                  :plan_hash, :verdict_hash, :verdicts_json, :excluded_json, :product_states_json, :reason, :confirmation_level,
                  :app_build, :estimate_requests, :estimate_minutes, :replan_of, :created_at, :updated_at, :heartbeat_at)
                """,
                arguments: try Self.arguments(for: plan))
            for item in items {
                try db.execute(
                    sql: """
                    INSERT INTO item (plan_id, seq, op, cell_key, before_json, target_json, payload_json, natural_key,
                      depends_on_json, rules_json, state, attempts, flags_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                    """,
                    arguments: [plan.id, item.seq, item.op.rawValue, item.cell.storageKey,
                                try JSONCoding.string(item.before), try JSONCoding.string(item.target),
                                try JSONCoding.string(item.payload), item.naturalKey,
                                try JSONCoding.string(item.dependsOn), try JSONCoding.string(item.rules),
                                ItemState.pending.rawValue, try JSONCoding.string(item.flags)])
            }
        }
    }

    public func plan(id: String) throws -> StoredPlan? {
        try database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM plan WHERE id = ?", arguments: [id]).map(Self.plan(from:))
        }
    }

    public func items(planId: String) throws -> [StoredItem] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM item WHERE plan_id = ? ORDER BY seq", arguments: [planId]).map(Self.item(from:))
        }
    }

    /// nil = every plan. Ordered by creation time.
    public func plans(states: Set<PlanState>?) throws -> [StoredPlan] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM plan ORDER BY created_at, id")
                .map(Self.plan(from:))
                .filter { states?.contains($0.state) ?? true }
        }
    }

    public func update(_ plan: StoredPlan, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE plan SET origin = :origin, spec_json = :spec_json, import_json = :import_json, binding_json = :binding_json,
              base_sync = :base_sync, state = :state, pause_reason = :pause_reason, end_reason = :end_reason,
              plan_hash = :plan_hash, verdict_hash = :verdict_hash, verdicts_json = :verdicts_json,
              excluded_json = :excluded_json, product_states_json = :product_states_json, reason = :reason,
              confirmation_level = :confirmation_level, app_build = :app_build, estimate_requests = :estimate_requests,
              estimate_minutes = :estimate_minutes, replan_of = :replan_of, created_at = :created_at,
              updated_at = :updated_at, heartbeat_at = :heartbeat_at
            WHERE id = :id
            """,
            arguments: try Self.arguments(for: plan))
    }

    public func update(_ item: StoredItem, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE item SET state = ?, attempts = ?, asc_id = ?, error_json = ?, verified_at = ?, effective_at = ?,
              superseded_by = ?, flags_json = ?
            WHERE plan_id = ? AND seq = ?
            """,
            arguments: [item.state.rawValue, item.attempts, item.ascId, item.errorJSON,
                        item.verifiedAt.map(Timestamp.string), item.effectiveAt.map(Timestamp.string),
                        item.supersededBy, try JSONCoding.string(item.item.flags), item.planId, item.item.seq])
    }

    public func itemsMatching(naturalKey: String) throws -> [StoredItem] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM item WHERE natural_key = ? ORDER BY plan_id, seq", arguments: [naturalKey])
                .map(Self.item(from:))
        }
    }

    public func itemsMatching(ascId: String) throws -> [StoredItem] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM item WHERE asc_id = ? ORDER BY plan_id, seq", arguments: [ascId])
                .map(Self.item(from:))
        }
    }

    // MARK: - Row mapping

    private static func arguments(for plan: StoredPlan) throws -> StatementArguments {
        [
            "id": plan.id,
            "origin": plan.origin.rawValue,
            "spec_json": plan.specJSON,
            "import_json": plan.importJSON,
            "binding_json": try JSONCoding.string(plan.binding),
            "base_sync": plan.baseSyncId,
            "state": plan.state.rawValue,
            "pause_reason": plan.pauseReason?.rawValue,
            "end_reason": plan.endReason?.rawValue,
            "plan_hash": plan.planHash,
            "verdict_hash": plan.verdictHash,
            "verdicts_json": try JSONCoding.string(plan.verdicts),
            "excluded_json": try JSONCoding.string(plan.excluded),
            "product_states_json": try JSONCoding.string(plan.productStates),
            "reason": plan.reason,
            "confirmation_level": plan.confirmationLevel.rawValue,
            "app_build": plan.appBuild,
            "estimate_requests": plan.estimateRequests,
            "estimate_minutes": plan.estimateMinutes,
            "replan_of": plan.replanOf,
            "created_at": Timestamp.string(plan.createdAt),
            "updated_at": Timestamp.string(plan.updatedAt),
            "heartbeat_at": plan.heartbeatAt.map(Timestamp.string),
        ]
    }

    private static func plan(from row: Row) throws -> StoredPlan {
        StoredPlan(
            id: row["id"],
            origin: try raw(PlanOrigin.self, row, "plan", "origin"),
            specJSON: row["spec_json"],
            importJSON: row["import_json"],
            binding: try JSONCoding.decode(PlanBinding.self, from: row["binding_json"]),
            baseSyncId: row["base_sync"],
            state: try raw(PlanState.self, row, "plan", "state"),
            pauseReason: try optionalRaw(PauseReason.self, row, "plan", "pause_reason"),
            endReason: try optionalRaw(PlanEndReason.self, row, "plan", "end_reason"),
            planHash: row["plan_hash"],
            verdictHash: row["verdict_hash"],
            verdicts: try JSONCoding.decode([Verdict].self, from: row["verdicts_json"]),
            excluded: try JSONCoding.decode([CellKey].self, from: row["excluded_json"]),
            productStates: try JSONCoding.decode([String: ProductState].self, from: row["product_states_json"]),
            reason: row["reason"],
            confirmationLevel: try raw(ConfirmationLevel.self, row, "plan", "confirmation_level"),
            appBuild: row["app_build"],
            estimateRequests: row["estimate_requests"],
            estimateMinutes: row["estimate_minutes"],
            replanOf: row["replan_of"],
            createdAt: try Timestamp.date(row["created_at"]),
            updatedAt: try Timestamp.date(row["updated_at"]),
            heartbeatAt: try (row["heartbeat_at"] as String?).map(Timestamp.date))
    }

    private static func item(from row: Row) throws -> StoredItem {
        let cellKey: String = row["cell_key"]
        guard let cell = CellKey(storageKey: cellKey) else {
            throw StoreError.corruptValue(table: "item", column: "cell_key", value: cellKey)
        }
        let planned = PlannedItem(
            seq: row["seq"],
            cell: cell,
            payload: try JSONCoding.decode(WritePayload.self, from: row["payload_json"]),
            before: try JSONCoding.decode(CellState.self, from: row["before_json"]),
            target: try JSONCoding.decode(CellState.self, from: row["target_json"]),
            dependsOn: try JSONCoding.decode([Int].self, from: row["depends_on_json"]),
            rules: try JSONCoding.decode([RuleID].self, from: row["rules_json"]),
            flags: try JSONCoding.decode([ItemFlag].self, from: row["flags_json"]))
        return StoredItem(
            planId: row["plan_id"],
            item: planned,
            state: try raw(ItemState.self, row, "item", "state"),
            attempts: row["attempts"],
            ascId: row["asc_id"],
            errorJSON: row["error_json"],
            verifiedAt: try (row["verified_at"] as String?).map(Timestamp.date),
            effectiveAt: try (row["effective_at"] as String?).map(Timestamp.date),
            supersededBy: row["superseded_by"])
    }

    private static func raw<T: RawRepresentable>(_ type: T.Type, _ row: Row, _ table: String, _ column: String) throws -> T
    where T.RawValue: DatabaseValueConvertible & CustomStringConvertible {
        let value: T.RawValue = row[column]
        guard let result = T(rawValue: value) else {
            throw StoreError.corruptValue(table: table, column: column, value: value.description)
        }
        return result
    }

    private static func optionalRaw<T: RawRepresentable>(_ type: T.Type, _ row: Row, _ table: String, _ column: String) throws -> T?
    where T.RawValue: DatabaseValueConvertible & CustomStringConvertible {
        guard let value = row[column] as T.RawValue? else { return nil }
        guard let result = T(rawValue: value) else {
            throw StoreError.corruptValue(table: table, column: column, value: value.description)
        }
        return result
    }
}
