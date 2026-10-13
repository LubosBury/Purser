import Foundation
import Domain

public enum SyncTrigger: String, Codable, Sendable { case nightly, manual, plan, preflight, verify }
public enum SyncScope: Hashable, Sendable { case all, products(Set<String>) }
public enum SyncStatus: String, Codable, Sendable { case complete, partial, failed }
public enum Provenance: String, Codable, Sendable { case baseline = "BASELINE", purser = "PURSER", apple = "APPLE", external = "EXTERNAL" }
public enum FindingType: String, Codable, Sendable { case external = "EXTERNAL", scheduleBroken = "SCHEDULE_BROKEN", invariant = "INVARIANT" }

public struct FindingRecord: Hashable, Sendable {
    public var id: Int64
    public var type: FindingType
    public var rule: RuleID?
    public var cell: CellKey
    public var fingerprint: String
    public var message: String
    public var firstSync: Int64
    public var lastSync: Int64
    public var planId: String?
    public var ackReason: String?
    public var ackAt: Date?

    public init(id: Int64, type: FindingType, rule: RuleID?, cell: CellKey, fingerprint: String, message: String,
                firstSync: Int64, lastSync: Int64, planId: String?, ackReason: String?, ackAt: Date?) {
        self.id = id; self.type = type; self.rule = rule; self.cell = cell; self.fingerprint = fingerprint
        self.message = message; self.firstSync = firstSync; self.lastSync = lastSync; self.planId = planId
        self.ackReason = ackReason; self.ackAt = ackAt
    }
}

public struct ObservationRecord: Hashable, Sendable {
    public var id: Int64
    public var kind: String                 // PRICE | INTRO | PROMO | PROMO_PRICE | IAP_SCHEDULE
    public var ascId: String
    public var cell: CellKey
    public var rawJSON: String
    public var firstSync: Int64
    public var lastSync: Int64
    public var provenance: Provenance
    public var expired: Bool

    public init(id: Int64, kind: String, ascId: String, cell: CellKey, rawJSON: String, firstSync: Int64, lastSync: Int64,
                provenance: Provenance, expired: Bool) {
        self.id = id; self.kind = kind; self.ascId = ascId; self.cell = cell; self.rawJSON = rawJSON
        self.firstSync = firstSync; self.lastSync = lastSync; self.provenance = provenance; self.expired = expired
    }
}

public struct SyncResult: Hashable, Sendable {
    public var syncId: Int64
    public var status: SyncStatus
    public var requestCount: Int
    public var newFindings: [FindingRecord]

    public init(syncId: Int64, status: SyncStatus, requestCount: Int, newFindings: [FindingRecord]) {
        self.syncId = syncId; self.status = status; self.requestCount = requestCount; self.newFindings = newFindings
    }
}

public enum SyncError: Error, Equatable, Sendable {
    /// GET /v1/apps/{appId} returned another bundle id than the workspace config (rule A1, D3).
    case bundleIdMismatch(expected: String, actual: String)
}

/// Observation kinds. A PROMO observation stores the whole offer including its price set (the promo cell, spec §5);
/// PROMO_PRICE stays reserved in the contract and is not written in v1.
public enum ObservationKind {
    public static let price = "PRICE"
    public static let intro = "INTRO"
    public static let promo = "PROMO"
    public static let promoPrice = "PROMO_PRICE"
    public static let iapSchedule = "IAP_SCHEDULE"

    public static let subscriptionKinds = [price, intro, promo]

    /// The (product, kind) scope string stored in sync_run.complete_scopes_json.
    public static func scope(product: String, kind: String) -> String { "\(product)|\(kind)" }
}
