import SwiftUI
import Domain
import Store
import Planner

/// "Plans" destination of the workspace window: the list of open plans, or the Plan screen of the one that is open.
struct PlanningRootView: View {
    @Bindable var model: PlanningModel
    var onNewPlan: () -> Void

    var body: some View {
        if let presentation = model.presentation {
            PlanView(model: model, presentation: presentation) { model.closePlan() }
        } else if let opening = model.opening {
            PlanLoadingView(plan: opening.plan) { model.closePlan() }
        } else {
            PlansListView(model: model, onNewPlan: onNewPlan)
        }
    }
}

struct NewPlanRequest: Identifiable {
    let id = UUID()
    var prefill: FixPrefill?
}

/// A stored plan as a table row.
struct PlanRow: Identifiable {
    let plan: StoredPlan
    var id: String { plan.id }
}

/// Plans that still need a decision or are waiting to take effect. Finished ones live in Historie.
struct PlansListView: View {
    @Bindable var model: PlanningModel
    var onNewPlan: () -> Void

    private var rows: [PlanRow] {
        model.plans
            .filter { $0.state != .effective && $0.state != .closed && $0.state != .cancelled }
            .sorted { $0.createdAt > $1.createdAt }
            .map(PlanRow.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space4) {
            PurserScreenHeader("Plans") {
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("New plan", action: onNewPlan)
                    .purserButton(primary: true)
                    .disabled(model.snapshot == nil)
            }
            if model.snapshot == nil {
                Text("A new plan can be created after the first sync.")
                    .font(PurserFont.callout)
                    .foregroundStyle(PurserColor.textSecondary)
            }
            if rows.isEmpty {
                ContentUnavailableView("No plans in progress", systemImage: "list.bullet.clipboard",
                                       description: Text("Finished plans are in History."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A click opens the Plan screen at once; it shows its own placeholder until the rows are ready.
                Table(rows, selection: Binding<String?>(
                    get: { nil },
                    set: { id in
                        guard let id else { return }
                        Task { await model.open(planId: id) }
                    })) {
                    TableColumn("Created") { row in
                        Text(row.plan.createdAt.formatted(date: .numeric, time: .shortened)).font(PurserFont.figure)
                    }
                    .width(140)
                    TableColumn("Plan") { row in Text(PlanFormatting.title(row.plan)) }
                    TableColumn("State") { row in PlanFormatting.stateBadge(row.plan) }
                        .width(180)
                    TableColumn("Estimate") { row in PurserFigure("\(row.plan.estimateMinutes) min") }
                        .width(80)
                }
                .purserTable()
            }
        }
        .padding(PurserSpacing.space5)
    }
}
