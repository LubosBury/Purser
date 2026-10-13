import Foundation
import GRDB
import Domain
import Store
import Audit

public enum PlanPersistenceError: Error, Equatable {
    case notFound(String)
    case notADraft(PlanState)
}

public struct PlanPersistence: Sendable {
    private let store: PlanStore
    private let audit: AuditLog
    private let appBuild: String
    private let now: @Sendable () -> Date
    private let makeId: @Sendable () -> String

    public init(store: PlanStore, audit: AuditLog, appBuild: String) {
        self.init(store: store, audit: audit, appBuild: appBuild, now: { Date() }, makeId: { UUID().uuidString })
    }

    init(store: PlanStore, audit: AuditLog, appBuild: String, now: @escaping @Sendable () -> Date, makeId: @escaping @Sendable () -> String) {
        self.store = store; self.audit = audit; self.appBuild = appBuild; self.now = now; self.makeId = makeId
    }

    /// Stores a Draft (state = draft) and logs planCreated; returns the plan id.
    public func saveDraft(_ draft: PlanDraft, binding: PlanBinding, reason: String?, replanOf: String?) throws -> String {
        let id = makeId()
        let timestamp = now()
        var importJSON: String?
        if case let .importTable(spec) = draft.spec.unwrapped { importJSON = try JSONCoding.string(spec.table) }
        let plan = StoredPlan(id: id, origin: draft.spec.origin, specJSON: try JSONCoding.string(draft.spec), importJSON: importJSON,
                              binding: binding, baseSyncId: draft.baseSyncId, state: .draft, pauseReason: nil, endReason: nil,
                              planHash: draft.planHash, verdictHash: draft.verdictHash, verdicts: draft.verdicts, excluded: draft.excluded,
                              productStates: [:], reason: reason, confirmationLevel: draft.confirmationLevel, appBuild: appBuild,
                              estimateRequests: draft.estimate.requests, estimateMinutes: draft.estimate.minutes, replanOf: replanOf,
                              createdAt: timestamp, updatedAt: timestamp, heartbeatAt: nil)
        try store.insert(plan, items: draft.items)
        var findingIds: [Int64] = []
        if case let .fix(ids, _) = draft.spec { findingIds = ids }
        // K3: refs keys are fixed (plan); replanOf goes to the payload.
        try audit.append(.planCreated, refs: ["plan": id], payload: PlanCreatedPayload(
            origin: draft.spec.origin.rawValue, planHash: draft.planHash, verdictHash: draft.verdictHash, items: draft.items.count,
            excluded: draft.excluded.count, confirmationLevel: draft.confirmationLevel.rawValue,
            estimateRequests: draft.estimate.requests, estimateMinutes: draft.estimate.minutes, baseSyncId: draft.baseSyncId,
            replanOf: replanOf, reason: reason, findingIds: findingIds, appBuild: appBuild))
        return id
    }

    /// Draft or Stale -> Cancelled (CANCELLED_BY_USER).
    public func cancel(planId: String) throws {
        try close(planId: planId, endReason: .cancelledByUser)
    }

    /// Re-plan: the new draft remembers the old plan (replanOf), the old Draft/Stale plan is closed as Cancelled (REPLANNED).
    public func replan(planId: String, with draft: PlanDraft, binding: PlanBinding, reason: String?) throws -> String {
        guard let old = try store.plan(id: planId) else { throw PlanPersistenceError.notFound(planId) }
        guard old.state == .draft || old.state == .stale else { throw PlanPersistenceError.notADraft(old.state) }
        let id = try saveDraft(draft, binding: binding, reason: reason ?? old.reason, replanOf: planId)
        try close(planId: planId, endReason: .replanned)
        return id
    }

    private func close(planId: String, endReason: PlanEndReason) throws {
        guard var plan = try store.plan(id: planId) else { throw PlanPersistenceError.notFound(planId) }
        guard plan.state == .draft || plan.state == .stale else { throw PlanPersistenceError.notADraft(plan.state) }
        let from = plan.state
        plan.state = .cancelled
        plan.endReason = endReason
        plan.updatedAt = now()
        try store.database.writer.write { db in
            try store.update(plan, in: db)
            try audit.append(.planStateChanged, refs: ["plan": planId],
                             payload: PlanStateChangedPayload(from: from.rawValue, to: PlanState.cancelled.rawValue, endReason: endReason.rawValue),
                             in: db)
        }
    }
}

struct PlanCreatedPayload: Encodable {
    var origin: String
    var planHash: String
    var verdictHash: String
    var items: Int
    var excluded: Int
    var confirmationLevel: Int
    var estimateRequests: Int
    var estimateMinutes: Int
    var baseSyncId: Int64
    var replanOf: String?
    var reason: String?
    var findingIds: [Int64]
    var appBuild: String
}

struct PlanStateChangedPayload: Encodable {
    var from: String
    var to: String
    var endReason: String
}
