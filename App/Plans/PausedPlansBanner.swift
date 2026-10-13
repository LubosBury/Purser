import SwiftUI
import Domain
import Store

/// "Apply paused (CRASH) at 212/525" banner (spec §8 flow 8). Recovery runs in the session (scheduleLaunchRecovery),
/// never from this view; the banner only reads the store.
struct PausedPlansBanner: View {
    struct PausedPlan: Identifiable, Equatable {
        let id: String
        let reason: PauseReason
        let done: Int
        let total: Int
    }

    let session: WorkspaceSession
    let controller: ApplyController
    @State private var paused: [PausedPlan] = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(paused) { plan in
                HStack(spacing: PurserSpacing.space3) {
                    PurserBadge(text: "Paused: \(plan.reason.rawValue.uppercased())", kind: .warning)
                    Text("The write stopped at \(plan.done) of \(plan.total).").font(PurserFont.body)
                    Spacer()
                    Button("Open plan") { session.showPlan(id: plan.id) }
                        .controlSize(.small)
                        .purserPlainButton()
                    Button("Continue") { controller.resume(planId: plan.id) }
                        .controlSize(.small)
                        .purserButton()
                        .disabled(controller.isRunning)
                }
                .padding(.horizontal, PurserSpacing.space4)
                .padding(.vertical, PurserSpacing.space2)
                .background(PurserColor.warningTint)
                .background(PurserColor.surface2)
            }
        }
        .task { reload() }
        .onChange(of: controller.phase) { _, _ in reload() }
        .onChange(of: session.applyRevision) { _, _ in reload() }
    }

    private func reload() {
        guard let plans = try? session.planStore.plans(states: [.applying]) else { return }
        paused = plans.compactMap { plan in
            guard let reason = plan.pauseReason, !(controller.isRunning && plan.id == controller.activePlanId),
                  let items = try? session.planStore.items(planId: plan.id) else { return nil }
            let done = items.filter { $0.state != .pending && $0.state != .inFlight }.count
            return PausedPlan(id: plan.id, reason: reason, done: done, total: items.count)
        }
    }
}
