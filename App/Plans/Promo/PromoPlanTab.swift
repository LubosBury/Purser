import SwiftUI
import Domain
import Planner

/// Promo tab of NewPlanSheet: loads the model from the planning snapshot.
struct PromoPlanHost: View {
    let planning: PlanningModel
    let onDone: () -> Void
    @State private var model: PromoPlanModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                PromoPlanTab(model: model, onDone: onDone)
            } else if let loadError {
                PlanFormMessage(loadError, kind: .danger).padding(PurserSpacing.space5)
            } else {
                ProgressView("Loading catalog…").padding(PurserSpacing.space5)
            }
        }
        .task {
            do {
                model = try PromoPlanModel.make(planning: planning)
                if model == nil { loadError = "The workspace has no sync yet. Start a sync in the sidebar." }
            } catch {
                loadError = String(describing: error)
            }
        }
    }
}

struct PromoPlanTab: View {
    @Bindable var model: PromoPlanModel
    let onDone: () -> Void
    @State private var saveError: String?
    @State private var saving = false

    var body: some View {
        HSplitView {
            PlanFormScaffold {
                PlanFormStep(1, "What to do with the offer") {
                    Picker("Action", selection: $model.action) {
                        ForEach(PromoPlanModel.Action.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                PlanFormStep(2, "Subscription") {
                    Picker("Subscription", selection: $model.subscriptionId) {
                        Text("Select…").tag(String?.none)
                        ForEach(model.subscriptions, id: \.ascId) { sub in
                            Text("\(sub.name) (\(sub.productId))").tag(Optional(sub.ascId))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                switch model.action {
                case .create: PromoCreateForm(model: model)
                case .reprice: PromoRepriceForm(model: model)
                case .delete: PromoDeleteForm(model: model)
                }
                PlanFormStep(model.action == .delete ? 4 : 5, "Reason") {
                    TextField("Reason", text: $model.reason, prompt: Text("Optional"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                PlanFormVerdicts(verdicts: model.planBlockingVerdicts)
            } footer: {
                PlanFormFooter(draft: model.draft, error: saveError ?? model.buildError, canSave: model.canSave && !saving, onCancel: onDone) {
                    saving = true
                    Task {
                        saveError = await model.save()
                        saving = false
                        if saveError == nil { onDone() }
                    }
                }
            }
            .frame(minWidth: 500)
            OfferCodeRegistryView(entries: model.registryEntries, subscriptions: model.snapshot.subscriptions)
                .frame(minWidth: 280)
        }
        .onChange(of: model.mode) {
            if model.mode != .payAsYouGo { model.numberOfPeriods = 1 }
            if model.mode == .freeTrial { model.pricingChoice = .freeTrial } else if model.pricingChoice == .freeTrial { model.pricingChoice = .percent }
        }
        .onChange(of: model.selectedOfferAscId) { model.confirmedUnusedByApp = false }
        .onChange(of: model.subscriptionId) { model.selectedOfferAscId = nil }
        .task(id: model.inputsFingerprint) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.rebuild()
        }
    }
}
