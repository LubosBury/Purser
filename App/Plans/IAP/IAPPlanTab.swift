import SwiftUI
import UniformTypeIdentifiers
import Domain
import Planner

/// IAP tab of NewPlanSheet: loads the model from the planning snapshot.
struct IAPPlanHost: View {
    let planning: PlanningModel
    let onDone: () -> Void
    @State private var model: IAPPlanModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                IAPPlanTab(model: model, onDone: onDone)
            } else if let loadError {
                PlanFormMessage(loadError, kind: .danger).padding(PurserSpacing.space5)
            } else {
                ProgressView("Loading catalog…").padding(PurserSpacing.space5)
            }
        }
        .task {
            model = IAPPlanModel.make(planning: planning)
            if model == nil { loadError = "The workspace has no sync yet. Start a sync in the sidebar." }
        }
    }
}

struct IAPPlanTab: View {
    @Bindable var model: IAPPlanModel
    let onDone: () -> Void
    @State private var importing = false
    @State private var saveError: String?
    @State private var saving = false

    private static func plain(_ value: Decimal?) -> String {
        value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "–"
    }

    var body: some View {
        VSplitView {
            PlanFormScaffold {
                PlanFormStep(1, "One-time purchase") {
                    Picker("One-time purchase", selection: Binding(get: { model.iapId }, set: { model.selectIAP($0) })) {
                        Text("Select…").tag(String?.none)
                        ForEach(model.iaps, id: \.ascId) { iap in Text("\(iap.name) (\(iap.productId))").tag(Optional(iap.ascId)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PlanFormStep(2, "Base territory", hint: "Apple derives from its price the territories that have no manual price.") {
                    Picker("Base territory", selection: $model.baseTerritory) {
                        ForEach(model.territories, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.iapId != nil, !model.baseHasManualPrice {
                        PlanFormMessage("The base territory \(model.baseTerritory.rawValue) has no manual price in the new prices.", kind: .warning)
                    }
                }
                PlanFormStep(3, "Manual prices") {
                    Picker("Source of manual prices", selection: $model.source) {
                        Text("Table").tag(IAPPlanModel.Source.table)
                        Text("CSV by mapping").tag(IAPPlanModel.Source.csv)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    switch model.source {
                    case .table:
                        PlanPriceTableEditor(title: "Price table", text: $model.tableText,
                                             hint: "The whole new schedule: one row = territory and manual price. Territories not listed here switch to the price derived from the base territory (L2).",
                                             errors: model.tableErrors.map { "Row \($0.line): \($0.message)" })
                    case .csv:
                        HStack(spacing: PurserSpacing.space3) {
                            Button("Choose CSV…") { importing = true }.purserButton()
                            if let status = model.csvStatus {
                                Text(status).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                            }
                        }
                    }
                }
                PlanFormStep(4, "Effective from") {
                    HStack(spacing: PurserSpacing.space4) {
                        Toggle("Manual prices start later", isOn: $model.startDateEnabled).toggleStyle(.checkbox)
                        if model.startDateEnabled {
                            DatePicker("Start (UTC)", selection: $model.startDate, displayedComponents: .date)
                                .labelsHidden()
                                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                            Text("UTC").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                        }
                    }
                }
                PlanFormStep(5, "Reason") {
                    TextField("Reason", text: $model.reason, prompt: Text("Optional"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                if !model.planBlockingVerdicts.isEmpty || !model.l3Verdicts.isEmpty {
                    VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                        PlanFormVerdicts(verdicts: model.planBlockingVerdicts)
                        ForEach(Array(model.l3Verdicts.enumerated()), id: \.offset) { _, verdict in
                            PlanFormMessage("L3 (C2): \(verdict.message)", kind: .warning)
                        }
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
            if let diff = model.diff {
                VStack(alignment: .leading, spacing: PurserSpacing.space2) {
                    Text("The whole schedule before and after (L1) · base \(diff.baseBefore?.rawValue ?? "–") → \(diff.baseAfter.rawValue)")
                        .font(PurserFont.headline)
                    Table(diff.rows) {
                        TableColumn("Territory") { row in Text(row.territory.rawValue) }
                        TableColumn("From") { row in Text(row.startDate?.iso ?? "now").font(PurserFont.figure) }
                        TableColumn("To") { row in Text(row.endDate?.iso ?? "–").font(PurserFont.figure) }
                        TableColumn("Before") { row in PurserFigure(Self.plain(row.before), color: PurserColor.textSecondary) }
                        TableColumn("After") { row in PurserFigure(Self.plain(row.after)) }
                        TableColumn("Change %") { row in PurserFigure(Self.plain(row.deltaPercent)) }
                        TableColumn("Change kind") { row in Text(row.change.rawValue).font(PurserFont.identifier).foregroundStyle(PurserColor.textSecondary) }
                    }
                    .purserTable()
                    DisclosureGroup("Territories with a price derived from the base territory (L2): \(diff.autoPricedTerritories.count)") {
                        VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                            PlanFormHint("Apple recalculates them from the base territory, including exchange rates and taxes. For manual prices, exchange rates and taxes are yours to watch.")
                            Text(diff.autoPricedTerritories.map(\.rawValue).joined(separator: ", "))
                                .font(PurserFont.identifier)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(PurserFont.callout)
                }
                .padding(PurserSpacing.space5)
                .frame(minHeight: 240)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText]) { result in
            if case let .success(url) = result { Task { await model.loadCSV(from: url) } }
        }
        .task(id: model.inputsFingerprint) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.rebuild()
        }
    }
}
