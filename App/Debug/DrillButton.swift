#if DEBUG
import SwiftUI
import Domain
import Planner
import Executor

/// S8 drill: creates a CANARY PATCH_END -> POST plan on PURSER_DRILL_SUBSCRIPTION (product id) in PURSER_DRILL_TERRITORY.
struct DrillButton: View {
    let session: WorkspaceSession
    @State private var message = "Creates a PATCH_END -> POST drill plan (DEBUG)"

    var body: some View {
        Button("Drill: PATCH_END → POST") { create() }
            .help(message)
    }

    private func create() {
        let environment = ProcessInfo.processInfo.environment
        guard let productId = environment["PURSER_DRILL_SUBSCRIPTION"], let territory = environment["PURSER_DRILL_TERRITORY"] else {
            message = "Set PURSER_DRILL_SUBSCRIPTION and PURSER_DRILL_TERRITORY in the scheme"
            return
        }
        do {
            guard let snapshot = try session.catalogStore.latestSnapshot(),
                  let subscription = snapshot.subscriptions.values.first(where: { $0.productId == productId }) else {
                message = "Sync first; \(productId) was not found"
                return
            }
            let today = CalendarDate.today(now: Date())
            let items = DrillPlanFactory.endThenPost(snapshot: snapshot, subscriptionId: subscription.ascId, territories: [TerritoryCode(territory)],
                                                     day: today.adding(days: 3), newDuration: .twoWeeks, today: today)
            guard !items.isEmpty else {
                message = "No current free trial without an end date in \(territory)"
                return
            }
            let draft = try DrillPlanFactory.draft(items: items, subscriptionId: subscription.ascId, baseSyncId: snapshot.syncId)
            let planId = try session.persistence.saveDraft(draft, binding: PlanBinding(config: session.config), reason: "S8 drill", replanOf: nil)
            Task { await session.planning.reload() }
            message = "Created drill plan \(planId); open it in Plans"
        } catch {
            message = String(describing: error)
        }
    }
}
#endif
