import Foundation
import Domain
import Store
import ASCClient
import Catalog
import Policy
import Planner

package enum PreflightMode: Sendable { case firstStart, resume }

/// A state change the resume preflight wants; the Executor persists it with an audit event.
package struct ItemChange: Hashable, Sendable {
    package var seq: Int
    package var to: ItemState
    package var ascId: String?
    package var note: String
    package init(seq: Int, to: ItemState, ascId: String?, note: String) { self.seq = seq; self.to = to; self.ascId = ascId; self.note = note }
}

package struct PreflightOutcome: Sendable {
    package var liveApp: ASCApp
    package var snapshot: CatalogSnapshot
    package var productStates: [String: ProductState]
    package var verdicts: [Verdict]
    package var verdictHash: String
    package var verdictHashChanged: Bool
    package var level: ConfirmationLevel
    package var planBlockers: [Verdict]
    package var cellBlockers: [CellKey: [Verdict]]
    package var staleCells: Set<CellKey>
    package var itemChanges: [ItemChange]
}

/// Spec §6 step 2. Reads only; never writes to ASC or to the database.
package struct Preflight: Sendable {
    let store: PlanStore
    let config: WorkspaceConfig
    let reader: any ASCReading
    let sync: SyncEngine
    let catalog: CatalogStore
    let policy: PolicyEngine
    let now: @Sendable () -> Date

    package init(store: PlanStore, config: WorkspaceConfig, reader: any ASCReading, sync: SyncEngine, catalog: CatalogStore,
                 policy: PolicyEngine, now: @escaping @Sendable () -> Date) {
        self.store = store; self.config = config; self.reader = reader; self.sync = sync
        self.catalog = catalog; self.policy = policy; self.now = now
    }

    package func run(planId: String, mode: PreflightMode) async throws -> PreflightOutcome {
        guard let plan = try store.plan(id: planId) else { throw ExecutorError.planNotFound(planId) }
        let items = try store.items(planId: planId)

        // A1: binding vs workspace config, then vs the live app.
        guard plan.binding == PlanBinding(config: config) else { throw ExecutorError.bindingMismatch("config") }
        let live = try await reader.app(id: plan.binding.appId)
        guard live.id == plan.binding.appId, live.bundleId == plan.binding.bundleId else { throw ExecutorError.bindingMismatch("live") }

        // A3: one applying plan per workspace.
        if let other = try store.plans(states: [.applying]).first(where: { $0.id != planId }) {
            throw ExecutorError.anotherPlanApplying(other.id)
        }

        // A4: targeted re-sync of affected products. Only the scopes the plan's cells need must be complete: a failed text
        // read does not stop a price plan, a failed price read does not stop a text plan.
        let products = Set(items.map { $0.item.cell.productAscId })
        let result = try await sync.sync(trigger: .preflight, scope: .products(products))
        guard result.isComplete(for: items.map(\.item.cell)) else { throw ExecutorError.syncIncomplete(result.status) }
        guard let snapshot = try catalog.latestSnapshot() else { throw ExecutorError.noSnapshot }
        let today = CalendarDate.today(now: now())

        // A5: product states, stored into the plan by the Executor. A subscription group has no product state; its texts
        // need only the group in the catalog.
        var states: [String: ProductState] = [:]
        var verdicts: [Verdict] = []
        let groups = Set(items.compactMap(\.item.cell.localizationOwner).filter { $0.kind == .group }.map(\.ascId))
        for group in groups.sorted() where snapshot.groups[group] == nil {
            verdicts.append(Verdict(rule: "A5", severity: .block(.plan), cell: nil, message: "Subscription group \(group) was not found in App Store Connect"))
        }
        for product in products.subtracting(groups).sorted() {
            guard let state = snapshot.subscriptions[product]?.state ?? snapshot.iaps[product]?.state else {
                verdicts.append(Verdict(rule: "A5", severity: .block(.plan), cell: nil, message: "Product \(product) was not found in App Store Connect"))
                continue
            }
            states[product] = state
            if !ProductState.writable.contains(state) {
                verdicts.append(Verdict(rule: "A5", severity: .block(.plan), cell: nil,
                                        message: "Product \(product) is \(state.rawValue); Purser writes only in APPROVED, READY_TO_SUBMIT, MISSING_METADATA, DEVELOPER_ACTION_NEEDED"))
            }
        }

        // Cells: 2a compares the first pending item; 2b walks each chain from its first unexecuted item.
        var staleCells = Set<CellKey>()
        var changes: [ItemChange] = []
        for (cell, chain) in Dictionary(grouping: items, by: { $0.item.cell }) {
            let ordered = chain.sorted { $0.item.seq < $1.item.seq }
            let liveState = snapshot.cellState(cell, on: today)
            switch mode {
            case .firstStart:
                guard let first = ordered.first(where: { $0.state == .pending }) else { continue }
                if !Reconciler.matches(live: liveState, expected: first.item.before, today: today) { staleCells.insert(cell) }
            case .resume:
                var index = ordered.firstIndex { $0.state == .pending || $0.state == .inFlight }
                while let i = index {
                    let stored = ordered[i]
                    index = nil
                    if stored.state == .pending {
                        if !Reconciler.matches(live: liveState, expected: stored.item.before, today: today) {
                            changes.append(ItemChange(seq: stored.item.seq, to: .stale, ascId: nil, note: "preflight 2b: live state differs from before"))
                        }
                        continue
                    }
                    switch Reconciler.resolve(stored.item, live: liveState, today: today) {
                    case let .targetFound(ascId):
                        changes.append(ItemChange(seq: stored.item.seq, to: .done, ascId: ascId ?? stored.ascId, note: "preflight 2b: target found"))
                        index = ordered[(i + 1)...].firstIndex { $0.state == .pending || $0.state == .inFlight }
                    case .unchanged:
                        if case .createMetadataVersion = stored.item.payload {
                            // L3: the POST may have created a version this read does not show yet. Apple cannot delete a
                            // version and refuses a second one, so it is never sent again; the texts wait for a replan.
                            changes.append(ItemChange(seq: stored.item.seq, to: .stale, ascId: nil,
                                                      note: "preflight 2b: the version may already exist although this read does not show it; re-sync and re-plan"))
                        } else {
                            changes.append(ItemChange(seq: stored.item.seq, to: .pending, ascId: nil, note: "preflight 2b: not applied, back to Pending"))
                        }
                    case .diverged:
                        changes.append(ItemChange(seq: stored.item.seq, to: .stale, ascId: nil, note: "preflight 2b: live state differs from before and target"))
                    }
                }
            }
        }

        // Re-policy over the items that are still to be written. An InFlight item 2b found written is not one of them:
        // its target is already the live state, so A4 checks the next item of its chain against it.
        let landed = Set(changes.filter { $0.to == .done }.map(\.seq))
        let remaining = items.filter { ($0.state == .pending || $0.state == .inFlight) && !landed.contains($0.item.seq) }
        let written = items.filter { $0.state == .done || $0.state == .effective || landed.contains($0.item.seq) }
        var liveBinding = PlanBinding(config: config)
        liveBinding.appId = live.id
        liveBinding.bundleId = live.bundleId
        let context = PolicyContext(snapshot: snapshot, config: config, today: today,
                                    spec: try PlanSpecSummarizer.summary(specJSON: plan.specJSON, config: config,
                                                                         unlockedCanaries: try LiveIntroCanaries.unlockedProducts(store: store)),
                                    items: remaining.map(\.item), liveBinding: liveBinding, liveBundleId: live.bundleId,
                                    otherApplyingPlanIds: [], writtenItems: written.map(\.item))
        verdicts += policy.evaluate(context)
        let verdictHash = PolicyEngine.hash(verdicts)
        let level = max(PolicyEngine.confirmationLevel(for: verdicts, config: config), plan.confirmationLevel)
        let remainingCells = Set(remaining.map { $0.item.cell })
        var cellBlockers: [CellKey: [Verdict]] = [:]
        for verdict in verdicts where verdict.severity == .block(.cell) {
            if let cell = verdict.cell, remainingCells.contains(cell) { cellBlockers[cell, default: []].append(verdict) }
        }

        return PreflightOutcome(liveApp: live, snapshot: snapshot, productStates: states, verdicts: verdicts, verdictHash: verdictHash,
                                verdictHashChanged: verdictHash != plan.verdictHash, level: level,
                                planBlockers: verdicts.filter { $0.severity == .block(.plan) }, cellBlockers: cellBlockers,
                                staleCells: staleCells, itemChanges: changes.sorted { $0.seq < $1.seq })
    }
}
