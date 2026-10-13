import SwiftUI
import Domain
import Planner

/// Regular price tab of NewPlanSheet: loads the model from the planning snapshot.
struct RegularPlanHost: View {
    let planning: PlanningModel
    let onDone: () -> Void
    @State private var model: RegularPlanModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                RegularPlanTab(model: model, onDone: onDone)
            } else if let loadError {
                PlanFormMessage(loadError, kind: .danger).padding(PurserSpacing.space5)
            } else {
                ProgressView("Loading catalog…").padding(PurserSpacing.space5)
            }
        }
        .task {
            model = RegularPlanModel.make(planning: planning)
            if model == nil { loadError = "The workspace has no sync yet. Start a sync in the sidebar." }
        }
    }
}

struct RegularPlanTab: View {
    @Bindable var model: RegularPlanModel
    let onDone: () -> Void
    @State private var saveError: String?
    @State private var saving = false

    var body: some View {
        PlanFormScaffold {
            PlanFormStep(1, "Products", hint: "Applies to pay up front. Monthly payment is blocked by rule R2.") {
                PlanFormList {
                    ForEach(model.subscriptions, id: \.ascId) { sub in
                        Toggle(isOn: Binding(
                            get: { model.selectedSubscriptionIds.contains(sub.ascId) },
                            set: { model.setSelected(sub.ascId, $0) })) {
                            HStack(spacing: PurserSpacing.space2) {
                                Text(sub.name)
                                Text(sub.productId).font(PurserFont.identifier).foregroundStyle(PurserColor.textSecondary)
                                Text(Formatting.productState(sub.state)).font(PurserFont.callout).foregroundStyle(PurserColor.textTertiary)
                            }
                        }
                    }
                }
            }
            PlanFormStep(2, "New prices") {
                HStack(alignment: .bottom, spacing: PurserSpacing.space3) {
                    PlanFormField("Base territory") {
                        TextField("Base territory", text: $model.baseTerritoryText, prompt: Text("USA")).font(PurserFont.figure)
                    }
                    .frame(width: 130)
                    PlanFormField("Price in this territory") {
                        TextField("Price", text: $model.baseAmountText, prompt: Text("29.99")).font(PurserFont.figure)
                    }
                    Button("Recalculate to all territories") { Task { await model.fillFromBasePrice() } }
                        .purserButton()
                        .disabled(model.isEqualizing)
                    if model.isEqualizing { ProgressView().controlSize(.small) }
                }
                if let message = model.equalizeMessage { PlanFormHint(message) }
                PlanPriceTableEditor(title: "Price table", text: $model.tableText,
                                     hint: "One row = territory (ASC code or name) and the new regular price. The price snaps to the nearest price point (S4).",
                                     errors: model.tableErrors.map { "Row \($0.line): \($0.message)" })
                PlanFormField("Only these territories") {
                    TextField("Only these territories", text: $model.territoryFilterText, prompt: Text("Empty = all from the table; otherwise codes separated by commas"))
                }
            }
            PlanFormStep(3, "Effective from") {
                HStack(spacing: PurserSpacing.space4) {
                    DatePicker("Start (UTC)", selection: $model.startDate, displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                        .disabled(model.startImmediately)
                    Text("UTC").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                    Toggle("First price of the product: effective at once, without a date", isOn: $model.startImmediately)
                        .toggleStyle(.checkbox)
                }
            }
            PlanFormStep(4, "Existing subscribers",
                         hint: "For an increase the choice is required and has no default. Raising the price for existing subscribers requires a reason at confirmation (C2, R8). For a decrease the price changes for everyone.") {
                Picker("Existing subscribers", selection: $model.preserve) {
                    Text("Not selected").tag(RegularPlanModel.PreserveChoice.unset)
                    Text("Keep their price").tag(RegularPlanModel.PreserveChoice.keep)
                    Text("Raise for them too").tag(RegularPlanModel.PreserveChoice.drop)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !model.i8Cells.isEmpty {
                PlanFormStep("Introductory offer replacements (I8)",
                             hint: "Replacements with the same date were added for the paid introductory offers. A cell can be left out only with a reason (C2).") {
                    ForEach(model.i8Cells, id: \.storageKey) { cell in
                        PlanFormField("Reason for leaving out \(cell.territory?.rawValue ?? cell.storageKey)") {
                            TextField("Reason for leaving out", text: Binding(
                                get: { model.skipReasons[cell.storageKey] ?? "" },
                                set: { model.skipReasons[cell.storageKey] = $0 }), prompt: Text("Empty = the replacement is written"))
                        }
                    }
                }
            }
            if !model.promoChoices.isEmpty {
                PlanFormStep("Pay-as-you-go promotional offers (O5)",
                             hint: "When the regular price goes down, the ticked offers are repriced in the same plan, before the regular price is written. When it goes up, promotional offers do not change.") {
                    PlanFormList {
                        ForEach($model.promoChoices) { $choice in
                            HStack(spacing: PurserSpacing.space2) {
                                Toggle(choice.offer.offerCode, isOn: $choice.enabled)
                                Spacer()
                                TextField("Percent of the new regular price", text: $choice.percentText)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .font(PurserFont.figure)
                                    .frame(width: 70)
                                    .disabled(!choice.enabled)
                                Text("% of the new regular price").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                            }
                        }
                    }
                }
            }
            PlanFormStep(5, "Reason") {
                TextField("Reason", text: $model.reason, prompt: Text("Optional. For example: yearly price adjustment for exchange rates"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            if !model.planBlockingVerdicts.isEmpty || !model.warnings.isEmpty {
                VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                    PlanFormVerdicts(verdicts: model.planBlockingVerdicts)
                    PlanFormVerdicts(verdicts: model.warnings)
                }
            }
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
        .task(id: model.inputsFingerprint) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.rebuild()
        }
    }
}
