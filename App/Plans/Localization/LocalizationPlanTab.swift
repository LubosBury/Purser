import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Domain

/// Localizations tab of NewPlanSheet: loads the model from the planning snapshot.
struct LocalizationPlanHost: View {
    let planning: PlanningModel
    let owner: LocalizationOwner?
    let onDone: () -> Void
    @State private var model: LocalizationPlanModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                LocalizationPlanTab(model: model, onDone: onDone)
            } else if let loadError {
                PlanFormMessage(loadError, kind: .danger).padding(PurserSpacing.space5)
            } else {
                ProgressView("Loading catalog…").padding(PurserSpacing.space5)
            }
        }
        .task {
            model = LocalizationPlanModel.make(planning: planning, owner: owner)
            if model == nil { loadError = "The workspace has no sync yet. Start a sync in the sidebar." }
        }
    }
}

struct LocalizationPlanTab: View {
    @Bindable var model: LocalizationPlanModel
    let onDone: () -> Void
    @State private var importing = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var exportMessage: String?

    var body: some View {
        PlanFormScaffold {
            PlanFormStep(1, "Source") {
                Picker("Source", selection: $model.source) {
                    ForEach(LocalizationPlanModel.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch model.source {
            case .editor: editorSteps
            case .table: tableStep
            }
            PlanFormStep(reasonStepNumber, "Reason") {
                TextField("Reason", text: $model.reason, prompt: Text("Optional. Why the texts change"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            PlanFormVerdicts(verdicts: model.blockingVerdicts)
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case let .success(url) = result { Task { await model.loadCSV(from: url) } }
        }
        // A save error belongs to the inputs it failed for.
        .onChange(of: model.inputsFingerprint) { saveError = nil }
        .task(id: model.inputsFingerprint) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.rebuild()
        }
    }

    /// The editor has a Texts step only once a product or group is chosen; the numbers stay without gaps.
    private var reasonStepNumber: Int {
        model.source == .editor && model.owner != nil ? 4 : 3
    }

    @ViewBuilder private var editorSteps: some View {
        PlanFormStep(2, "Product or group") {
            Picker("Product or group", selection: Binding(get: { model.owner }, set: { model.select($0) })) {
                Text("Select…").tag(LocalizationOwner?.none)
                ForEach(model.owners, id: \.self) { owner in Text(model.label(owner)).tag(Optional(owner)) }
            }
            .labelsHidden()
            .fixedSize()
            if model.owner != nil, !model.hasPendingVersion {
                PlanFormMessage("\(model.isGroup ? "This group" : "This product") has no version in preparation. The plan first creates a new version (rule N5), which App Store Connect cannot delete through the API; you submit it for review in App Store Connect (Purser never does).",
                                kind: .warning)
            }
        }
        if model.owner != nil {
            PlanFormStep(3, "Texts", hint: "An empty field keeps the current text. Locales and texts cannot be removed here.") {
                PlanFormList {
                    Grid(alignment: .leading, horizontalSpacing: PurserSpacing.space3, verticalSpacing: PurserSpacing.space2) {
                        GridRow {
                            Text("Locale")
                            Text("Name")
                            Text(model.isGroup ? "Custom app name" : "Description")
                            Text("Version")
                        }
                        .font(PurserFont.headline)
                        .foregroundStyle(PurserColor.textSecondary)
                        ForEach($model.rows) { $row in
                            GridRow {
                                Text(row.locale).font(PurserFont.identifier)
                                TextField("Name", text: $row.name)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Name, \(row.locale)")
                                if model.isGroup {
                                    TextField("Custom app name", text: $row.customAppName)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Custom app name, \(row.locale)")
                                } else {
                                    TextField("Description", text: $row.description)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Description, \(row.locale)")
                                }
                                badge(row.version)
                            }
                        }
                    }
                }
                HStack(spacing: PurserSpacing.space2) {
                    Picker("Add locale", selection: $model.newLocale) {
                        ForEach(model.addableLocales, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Add locale") { model.addLocale() }
                        .purserButton()
                        .disabled(model.newLocale.isEmpty)
                }
            }
        }
    }

    private var tableStep: some View {
        PlanFormStep(2, "Table", hint: "Columns: product (Product ID, or group:<reference name>), locale, name, description, custom_app_name. An empty cell keeps the current text.") {
            HStack(spacing: PurserSpacing.space2) {
                Button("Load CSV…") { importing = true }.purserButton()
                Button("Download CSV template…") { saveTemplate() }.purserPlainButton()
                Spacer()
            }
            PlanFormHint("A leading ' before = + - @ stops spreadsheets from running a text as a formula; Purser removes it on import.")
            if model.config.googleClientId != nil {
                HStack(alignment: .bottom, spacing: PurserSpacing.space3) {
                    PlanFormField("Google Sheet ID") { TextField("Google Sheet ID", text: $model.sheetId) }
                    PlanFormField("Range") { TextField("Range", text: $model.sheetRange) }
                    Button("Load Google Sheet") { Task { await model.loadSheet() } }
                        .purserButton()
                        .disabled(!model.canLoadSheet)
                }
            }
            if let status = model.tableStatus { PlanFormHint(status) }
            if let exportMessage { PlanFormHint(exportMessage) }
            ForEach(model.tableProblems, id: \.self) { PlanFormMessage($0, kind: .danger) }
        }
    }

    /// The same words and icons as the catalog's Localizations section; never color alone.
    private func badge(_ version: LocalizationPlanModel.Version) -> PurserBadge {
        switch version {
        case .draft: return PurserBadge(text: "Draft", kind: .neutral, icon: "pencil")
        case .inReview: return PurserBadge(text: "In review", kind: .info, icon: "clock")
        case .live: return PurserBadge(text: "Live", kind: .success, icon: "checkmark")
        case .new: return PurserBadge(text: "New", kind: .info, icon: "plus")
        }
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "purser-localizations-\(model.config.name.replacingOccurrences(of: " ", with: "-")).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try model.exportTemplate(to: url)
            exportMessage = "Template saved with the texts of \(count) products and groups."
        } catch {
            exportMessage = "The template cannot be saved: \(error)"
        }
    }
}
