import Foundation
import Domain
import Store
import Audit
import Catalog
import Importer
import Policy
import Planner

extension Executor {
    /// Called after each sync: Scheduled -> Effective, late verification of Mismatch, Superseded/Withdrawn marking.
    /// Items are followed to effectiveness even after Closed. Never raises findings.
    public func reconcileAfterSync(_ snapshot: CatalogSnapshot) async throws {
        let today = self.today
        for plan in try store.plans(states: [.scheduled, .partiallyApplied, .closed]) where !running.contains(plan.id) {
            try loadLedger(plan.id)
            for stored in (ledgers[plan.id] ?? [:]).values.sorted(by: { $0.item.seq < $1.item.seq }) {
                switch stored.state {
                case .mismatch:
                    if let remover = try remover(of: stored) {
                        try markRemoved(stored, by: remover)
                    } else {
                        let live = snapshot.cellState(stored.item.cell, on: today)
                        guard Reconciler.reached(stored.item, live: live, today: today) else { continue }
                        let ascId = Reconciler.createdAscId(stored.item.payload, live: live, today: today) ?? stored.ascId
                        let at = now()
                        try setItem(plan.id, stored.item.seq, to: .done, ascId: ascId, note: "late verified by sync \(snapshot.syncId)",
                                    mutate: { $0.verifiedAt = at })
                        try audit.append(.verify, refs: ["plan": plan.id, "product": stored.item.cell.productAscId],
                                         payload: VerifyPayload(product: stored.item.cell.productAscId, attempt: 0,
                                                                verified: [stored.item.seq], missing: [], late: true))
                    }
                case .done:
                    if let remover = try remover(of: stored) {
                        try markRemoved(stored, by: remover)
                    } else if ItemEffectiveness.inSnapshot(stored, snapshot: snapshot, today: today) {
                        let at = now()
                        try setItem(plan.id, stored.item.seq, to: .effective, note: "effective in sync \(snapshot.syncId)",
                                    mutate: { $0.effectiveAt = at })
                    } else if plan.state == .scheduled, !ItemEffectiveness.stillPresent(stored, snapshot: snapshot, today: today) {
                        try setItem(plan.id, stored.item.seq, to: .mismatch, note: "the written row disappeared without a Purser item explaining it")
                    }
                default:
                    break
                }
            }
            if plan.state == .scheduled, let outcome = OutcomeCalculator.afterSync(Array((ledgers[plan.id] ?? [:]).values)) {
                try setPlan(plan.id, to: outcome.state, pause: nil, endReason: outcome.endReason, note: "after sync \(snapshot.syncId)")
            }
            ledgers[plan.id] = nil
        }
    }

    /// The Done/Effective item of another plan that deleted the row this item created.
    func remover(of stored: StoredItem) throws -> (planId: String, withdrawn: Bool)? {
        guard let ascId = stored.ascId else { return nil }
        let key: String
        switch stored.item.payload {
        case .createRegularPrice: key = NaturalKey.of(.deleteRegularPrice(ascId: ascId))
        case .createIntro: key = NaturalKey.of(.deleteIntro(ascId: ascId))
        case .createPromo: key = NaturalKey.of(.deletePromo(ascId: ascId))
        default: return nil
        }
        for candidate in try store.itemsMatching(naturalKey: key)
        where candidate.planId != stored.planId && (candidate.state == .done || candidate.state == .effective) {
            return (candidate.planId, try store.plan(id: candidate.planId)?.origin == .withdraw)
        }
        return nil
    }

    func markRemoved(_ stored: StoredItem, by remover: (planId: String, withdrawn: Bool)) throws {
        try setItem(stored.planId, stored.item.seq, to: remover.withdrawn ? .withdrawn : .superseded,
                    note: "row removed by plan \(remover.planId)", mutate: { $0.supersededBy = remover.planId })
    }

    func freshSnapshot(products: Set<String>) async throws -> CatalogSnapshot {
        let result = try await sync.sync(trigger: .plan, scope: .products(products))
        guard result.status == .complete else { throw ExecutorError.syncIncomplete(result.status) }
        guard let snapshot = try catalog.latestSnapshot() else { throw ExecutorError.noSnapshot }
        return snapshot
    }

    /// Cells whose expected state belongs to a plan created after `plan` (spec §6 "Replan the rest").
    func cellsOwnedByNewerPlans(than plan: StoredPlan) throws -> Set<CellKey> {
        let newer = try store.plans(states: [.applying, .scheduled, .effective, .partiallyApplied, .closed])
            .filter { $0.id != plan.id && $0.createdAt > plan.createdAt }
        return Set(try newer.flatMap { try store.items(planId: $0.id).map(\.item.cell) })
    }

    /// The sheet can be re-read only by the app; pass the fresh table through `replanRest(planId:planner:freshTable:)`.
    public func replanRest(planId: String, planner: Planner, rereadSheet: Bool) async throws -> String {
        if rereadSheet { throw ExecutorError.freshTableRequired }
        return try await replanRest(planId: planId, planner: planner, freshTable: nil)
    }

    public func replanRest(planId: String, planner: Planner, freshTable: ImportedTable?) async throws -> String {
        let plan = try loadPlan(planId)
        guard plan.state == .partiallyApplied else { throw ExecutorError.invalidState(plan.state) }
        guard var spec = try? JSONCoding.decode(PlanSpec.self, from: plan.specJSON) else {
            throw ExecutorError.corruptPlan("spec_json is not a PlanSpec")
        }
        if let freshTable, case var .importTable(importSpec) = spec {
            importSpec.table = freshTable
            spec = .importTable(importSpec)
        }
        let products = Set(try store.items(planId: planId).map { $0.item.cell.productAscId })
        let snapshot = try await freshSnapshot(products: products)
        let today = self.today
        // The Planner has no database: a WITHDRAW spec needs the stored items of the plan it refers to (K9 referencedItems).
        var referenced: [String: [StoredItem]] = [:]
        if case let .withdraw(withdraw) = spec.unwrapped { referenced[withdraw.planId] = try store.items(planId: withdraw.planId) }
        let unlockedCanaries = try LiveIntroCanaries.unlockedProducts(store: store)
        var draft = try planner.plan(spec, context: PlanningContext(snapshot: snapshot, config: config, today: today,
                                                                    rateLimit: await budget?.latest, referencedItems: referenced,
                                                                    effectiveLiveIntroCanaryProducts: unlockedCanaries))
        let removed = Set(draft.items.map(\.cell)).intersection(try cellsOwnedByNewerPlans(than: plan))
        if !removed.isEmpty {
            draft.items = draft.items.filter { !removed.contains($0.cell) }
            draft.excluded = Array(Set(draft.excluded).union(removed)).sorted { $0.storageKey < $1.storageKey }
            let context = PolicyContext(snapshot: snapshot, config: config, today: today,
                                        spec: PlanSpecSummarizer.summary(spec, config: config, unlockedCanaries: unlockedCanaries), items: draft.items,
                                        liveBinding: nil, liveBundleId: nil, otherApplyingPlanIds: [])
            draft.verdicts = policy.evaluate(context)
            draft.verdictHash = PolicyEngine.hash(draft.verdicts)
            draft.confirmationLevel = PolicyEngine.confirmationLevel(for: draft.verdicts, config: config)
            draft.planHash = try PlanHasher.hash(draft.items)
        }
        let newId = try PlanPersistence(store: store, audit: audit, appBuild: BuildInfo.current)
            .saveDraft(draft, binding: PlanBinding(config: config), reason: nil, replanOf: planId)
        try setPlan(planId, to: .closed, pause: nil, endReason: .replanned, note: "replanned as \(newId)")
        return newId
    }

    static func isFutureDated(_ item: PlannedItem, today: CalendarDate) -> Bool {
        switch item.payload {
        case let .createRegularPrice(p): return p.startDate.map { $0 > today } ?? false
        case let .createIntro(o): return o.startDate.map { $0 > today } ?? false
        default: return false
        }
    }

    /// WITHDRAW plan for Done items with a future date (R6 is checked by the Planner's policy). K10: PartiallyApplied
    /// (the plan becomes Closed/withdrawn) or Scheduled (spec §8 "Roll back": the plan stays Scheduled; once the deletes are
    /// written, reconcileAfterSync marks its items Withdrawn and the plan becomes Cancelled/withdrawn).
    public func withdrawWritten(planId: String, planner: Planner) async throws -> String {
        let plan = try loadPlan(planId)
        guard plan.state == .partiallyApplied || plan.state == .scheduled else { throw ExecutorError.invalidState(plan.state) }
        let today = self.today
        let items = try store.items(planId: planId)
        let seqs = items.filter { $0.state == .done && Self.isFutureDated($0.item, today: today) }.map(\.item.seq).sorted()
        guard !seqs.isEmpty else { throw ExecutorError.nothingToWithdraw }
        let snapshot = try await freshSnapshot(products: Set(items.map { $0.item.cell.productAscId }))
        let draft = try planner.plan(.withdraw(WithdrawPlanSpec(planId: planId, itemSeqs: seqs)),
                                     context: PlanningContext(snapshot: snapshot, config: config, today: today,
                                                              rateLimit: await budget?.latest, referencedItems: [planId: items]))
        let newId = try PlanPersistence(store: store, audit: audit, appBuild: BuildInfo.current)
            .saveDraft(draft, binding: PlanBinding(config: config), reason: nil, replanOf: planId)
        // A Scheduled plan stays Scheduled (the new Draft's planCreated event carries replanOf = planId).
        if plan.state == .partiallyApplied {
            try setPlan(planId, to: .closed, pause: nil, endReason: .withdrawn, note: "withdrawal planned as \(newId)")
        }
        return newId
    }

    public func close(planId: String, reason: String) async throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExecutorError.reasonRequired }
        let plan = try loadPlan(planId)
        guard plan.state == .partiallyApplied else { throw ExecutorError.invalidState(plan.state) }
        try setPlan(planId, to: .closed, pause: nil, endReason: .abandoned, note: "closed: \(trimmed)")
    }
}
