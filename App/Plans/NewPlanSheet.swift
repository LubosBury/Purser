import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Domain
import Importer
import Policy
import Planner

enum PreserveChoice: String, CaseIterable, Identifiable {
    case unset = "Not chosen", yes = "Yes (existing subscribers keep theirs)", no = "No (raise for existing subscribers too)"
    var id: String { rawValue }
    var value: Bool? { self == .unset ? nil : self == .yes }
}

enum PricingKind: String, CaseIterable, Identifiable {
    case free = "Free trial", percent = "% of the regular price", table = "Price table", trialLengths = "Trial lengths"
    var id: String { rawValue }
}

/// New plan: tabs Import / Intro / Promo / IAP / Regular price, product and territory filter, CANARY. "Build plan" stores a Draft.
struct NewPlanSheet: View {
    @Bindable var model: PlanningModel
    let prefill: FixPrefill?
    let localizationOwner: LocalizationOwner?
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case regular = "Regular price", intro = "Introductory offer", promo = "Promotional offer", iap = "One-time purchase", importTable = "Table import",
             localization = "Localizations"
        var id: String { rawValue }
    }

    @State private var tab: Tab
    @State private var selectedProducts: Set<String> = []
    @State private var territoryText = ""
    @State private var canary = false
    @State private var reason = ""
    @State private var problems: [String] = []

    @State private var imported: ImportOutcome?
    @State private var writeColumns: Set<String> = []
    @State private var importStartEnabled = false
    @State private var importStart = Date().addingTimeInterval(7 * 86_400)
    @State private var preserve: PreserveChoice = .unset
    @State private var showFileImporter = false
    @State private var templateMessage: String?

    @State private var introMode: OfferMode = .payUpFront
    @State private var introDuration: OfferDuration = .oneYear
    @State private var introPeriods = 1
    @State private var introPricing: PricingKind = .percent
    @State private var introPercent = "80"
    @State private var introTable = ""
    @State private var introStartEnabled = false
    @State private var introStart = Date().addingTimeInterval(7 * 86_400)
    @State private var introEndEnabled = false
    @State private var introEnd = Date().addingTimeInterval(90 * 86_400)
    @State private var introNominal = ""

    /// `tab` is where the sheet opens; it is set here so that no other tab renders (and starts loading) for a first frame.
    init(model: PlanningModel, prefill: FixPrefill?, localizationOwner: LocalizationOwner? = nil, tab: Tab? = nil) {
        self.model = model
        self.prefill = prefill
        self.localizationOwner = localizationOwner
        _tab = State(initialValue: tab ?? .regular)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceBanner(config: model.config)
            VStack(alignment: .leading, spacing: PurserSpacing.space3) {
                Text(prefill == nil ? "New plan" : "Repair plan").font(PurserFont.title2)
                VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                    Text("What should change").font(PurserFont.headline).foregroundStyle(PurserColor.textSecondary)
                    Picker("What should change", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(prefill != nil)
                }
            }
            .padding(PurserSpacing.space5)
            switch tab {
            case .promo:
                PromoPlanHost(planning: model) { dismiss() }
            case .iap:
                IAPPlanHost(planning: model) { dismiss() }
            case .regular:
                RegularPlanHost(planning: model) { dismiss() }
            case .localization:
                LocalizationPlanHost(planning: model, owner: localizationOwner) { dismiss() }
            case .importTable, .intro:
                legacyForm
            }
        }
        .frame(minWidth: 860, idealWidth: 900, minHeight: 680)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case let .success(url) = result { Task { await load { await model.importCSV(from: url) } } }
        }
        .onAppear(perform: applyPrefill)
    }

    /// Intro and Import are built by this sheet itself; the other kinds bring their own model and form.
    private var legacyForm: some View {
        PlanFormScaffold {
            switch tab {
            case .importTable: importTab
            case .intro: introTab
            case .promo, .iap, .regular, .localization: EmptyView()
            }
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                    ForEach(problems, id: \.self) { PlanFormMessage($0, kind: .danger) }
                }
            }
        } footer: {
            PlanFormFooter(canSave: !model.isWorking && !(tab == .importTable && (imported == nil || imported?.hasBlock == true)),
                           onCancel: { dismiss() }, onSave: build)
        }
    }

    // MARK: tabs

    @ViewBuilder private var importTab: some View {
        PlanFormStep(1, "Source", hint: model.config.importMapping == nil
            ? "Download the template, edit the prices in it and load it back. The template sets the column mapping by itself." : nil) {
            HStack(spacing: PurserSpacing.space2) {
                if case .googleSheet = model.config.importMapping?.source {
                    Button("Load Google Sheet") { Task { await load { await model.importGoogleSheet() } } }
                        .purserButton()
                        .disabled(!model.google.isSignedIn)
                }
                Button("Load CSV…") { showFileImporter = true }.purserButton()
                Button("Download CSV template…") { saveTemplate() }
                    .purserPlainButton()
                    .disabled(model.snapshot == nil)
                Spacer()
                if let imported {
                    Text("\(imported.table.rows.count) rows · sha256 \(imported.table.sha256.prefix(12))…")
                        .font(PurserFont.identifier)
                        .foregroundStyle(PurserColor.textSecondary)
                }
            }
            if let templateMessage { PlanFormHint(templateMessage) }
            PlanFormVerdicts(verdicts: imported?.verdicts ?? [])
        }
        if let mapping = model.config.importMapping {
            PlanFormStep(2, "Columns", hint: "Checked columns are written; the others are only compared with the live prices.") {
                PlanFormList {
                    ForEach(mapping.targets, id: \.column) { target in
                        Toggle(isOn: Binding(
                            get: { writeColumns.contains(target.column.uppercased()) },
                            set: { if $0 { writeColumns.insert(target.column.uppercased()) } else { writeColumns.remove(target.column.uppercased()) } })) {
                            Text("\(target.column) · \(model.productName(target.productAscId)) · \(describe(target.kind))\(target.nominalDiscount.map { " · nominal \(PlanFormatting.percent($0))" } ?? "")")
                        }
                        .disabled(!target.writes)
                    }
                }
            }
            PlanFormStep(3, "Effective from") {
                dateRow("Set a start date", isOn: $importStartEnabled, date: $importStart)
            }
            PlanFormStep(4, "Existing subscribers", hint: "Applies only to regular price increases.") {
                Picker("Existing subscribers", selection: $preserve) {
                    Text("Not selected").tag(PreserveChoice.unset)
                    Text("Keep their price").tag(PreserveChoice.yes)
                    Text("Raise for them too").tag(PreserveChoice.no)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            scopeStep(5)
            reasonStep(6)
        }
    }

    @ViewBuilder private var introTab: some View {
        PlanFormStep(1, "Products") {
            PlanFormList {
                ForEach(model.subscriptions, id: \.ascId) { sub in
                    Toggle(isOn: Binding(
                        get: { selectedProducts.contains(sub.ascId) },
                        set: { if $0 { selectedProducts.insert(sub.ascId) } else { selectedProducts.remove(sub.ascId) } })) {
                        HStack(spacing: PurserSpacing.space2) {
                            Text(sub.name)
                            Text("\(Formatting.period(sub.period)) · \(Formatting.productState(sub.state))").font(PurserFont.callout).foregroundStyle(PurserColor.textTertiary)
                        }
                    }
                }
            }
        }
        PlanFormStep(2, "Offer") {
            HStack(alignment: .top, spacing: PurserSpacing.space3) {
                PlanFormField("Payment mode") {
                    Picker("Payment mode", selection: $introMode) {
                        ForEach(OfferMode.allCases, id: \.self) { Text(PlanFormatting.modeLabel($0)).tag($0) }
                    }
                    .fixedSize()
                }
                PlanFormField("Duration") {
                    Picker("Duration", selection: $introDuration) {
                        ForEach(OfferDuration.allCases, id: \.self) { Text(PlanFormatting.durationLabel($0)).tag($0) }
                    }
                    .fixedSize()
                }
                if introMode == .payAsYouGo {
                    PlanFormField("Number of periods") {
                        Stepper("\(introPeriods)", value: $introPeriods, in: 1...12)
                        Text("\(introPeriods)").font(PurserFont.figure)
                    }
                }
            }
        }
        PlanFormStep(3, "Price") {
            Picker("Price", selection: $introPricing) {
                Text("Free").tag(PricingKind.free)
                Text("Percent of the regular price").tag(PricingKind.percent)
                Text("Price table").tag(PricingKind.table)
                Text("Trial durations").tag(PricingKind.trialLengths)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch introPricing {
            case .free:
                PlanFormHint("A free trial offer, without a price.")
            case .percent:
                percentRow("% of the regular price during the offer, rounded down to the nearest price point", text: $introPercent)
            case .table:
                PlanPriceTableEditor(title: "Price table", text: $introTable, hint: "One row = territory and price, for example “USA 23.99”.")
            case .trialLengths:
                PlanPriceTableEditor(title: "Duration table", text: $introTable,
                                     hint: "One row = territory and duration, for example “USA ONE_MONTH” or “DEU 14”.")
            }
            percentRow("% nominal discount (I5), optional", text: $introNominal)
        }
        PlanFormStep(4, "Validity") {
            dateRow("Set a start date", isOn: $introStartEnabled, date: $introStart)
            dateRow("Set an end date", isOn: $introEndEnabled, date: $introEnd)
        }
        scopeStep(5)
        reasonStep(6)
    }

    private func scopeStep(_ number: Int) -> some View {
        PlanFormStep(number, "Range") {
            PlanFormField("Only these territories") {
                TextField("Only these territories", text: $territoryText, prompt: Text("Empty = all; otherwise for example USA, CZE"))
            }
            Toggle("Try it first on one territory per product (CANARY)", isOn: $canary).toggleStyle(.checkbox)
        }
    }

    private func reasonStep(_ number: Int) -> some View {
        PlanFormStep(number, "Reason") {
            TextField("Reason", text: $reason, prompt: Text("Optional. Why the plan exists"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func dateRow(_ label: String, isOn: Binding<Bool>, date: Binding<Date>) -> some View {
        HStack(spacing: PurserSpacing.space4) {
            Toggle(label, isOn: isOn).toggleStyle(.checkbox)
            if isOn.wrappedValue {
                DatePicker(label, selection: date, displayedComponents: .date).labelsHidden()
                Text("UTC").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
            }
        }
    }

    private func percentRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: PurserSpacing.space2) {
            TextField(label, text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(PurserFont.figure)
                .frame(width: 70)
            Text(label).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
        }
    }

    // MARK: building

    private func build() {
        problems = []
        guard let spec = makeSpec() else { return }
        Task {
            if await model.build(spec, reason: reason.isEmpty ? nil : reason) { dismiss() }
        }
    }

    private func makeSpec() -> PlanSpec? {
        let territories = PastedTable.territories(territoryText, names: model.names)
        problems += territories.errors
        let filter = PlanFilter(productAscIds: selectedProducts.isEmpty ? nil : selectedProducts, territories: territories.territories)
        let spec: PlanSpec?
        switch tab {
        case .importTable: spec = importSpec(filter: filter)
        case .intro: spec = introSpec(filter: filter)
        case .promo: spec = nil   // M4: PromoPlanTab builds and saves promo plans itself
        case .iap: spec = nil   // M4: IAPPlanTab builds and saves IAP plans itself
        case .regular: spec = nil   // M4: RegularPlanTab builds and saves regular price plans itself
        case .localization: spec = nil   // L2: LocalizationPlanTab builds and saves L10N plans itself
        }
        guard problems.isEmpty, let spec else { return nil }
        if let prefill { return .fix(findingIds: prefill.findingIds, underlying: spec) }
        return spec
    }

    /// Saves the predefined table for this workspace and switches the workspace to its column layout.
    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "purser-prices-\(model.config.name.replacingOccurrences(of: " ", with: "-")).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let export = try model.exportImportTemplate(to: url)
            imported = nil
            writeColumns = Set((model.config.importMapping?.targets ?? []).filter(\.writes).map { $0.column.uppercased() })
            var message = "Template saved: \(export.productCount) subscriptions × \(export.territoryCount) territories, mapping v\(export.mappingVersion)."
            if !export.withoutPrice.isEmpty {
                message += " Left out because they have no price: \(export.withoutPrice.joined(separator: ", ")) (set the first price on the Regular price tab)."
            }
            if !export.skippedTerritories.isEmpty {
                message += " Territories without a known name: \(export.skippedTerritories.map(\.rawValue).joined(separator: ", "))."
            }
            templateMessage = message
        } catch {
            templateMessage = "The template cannot be saved: \(error)"
        }
    }

    private func importSpec(filter: PlanFilter) -> PlanSpec? {
        guard let imported else { problems.append("Load the table first."); return nil }
        return .importTable(ImportPlanSpec(table: imported.table, writeColumns: writeColumns.sorted(), filter: filter,
                                           startDate: importStartEnabled ? CalendarDate.today(now: importStart) : nil,
                                           preserveCurrentPrice: preserve.value, canary: canary))
    }

    private func introSpec(filter: PlanFilter) -> PlanSpec? {
        guard !selectedProducts.isEmpty else { problems.append("Select at least one product."); return nil }
        let pricing: IntroPricing
        switch introPricing {
        case .free: pricing = .freeTrial
        case .percent:
            guard let percent = ImportValueParser.amount(introPercent), percent < 100 else { problems.append("The percentage must be a number 0–100."); return nil }
            pricing = .percentOfRegular(percent / 100)
        case .table:
            let parsed = PastedTable.amounts(introTable, names: model.names)
            problems += parsed.errors
            pricing = .table(parsed.amounts)
        case .trialLengths:
            let parsed = PastedTable.durations(introTable, names: model.names)
            problems += parsed.errors
            pricing = .trialLengths(parsed.durations)
        }
        var nominal: Decimal?
        if !introNominal.isEmpty {
            guard let value = ImportValueParser.amount(introNominal), value < 100 else { problems.append("The nominal discount must be 0–100%."); return nil }
            nominal = value / 100
        }
        let mode: OfferMode = (introPricing == .free || introPricing == .trialLengths) ? .freeTrial : introMode
        return .intro(IntroPlanSpec(subscriptionIds: selectedProducts.sorted(), mode: mode, duration: introDuration,
                                    numberOfPeriods: mode == .payAsYouGo ? introPeriods : 1, pricing: pricing,
                                    startDate: introStartEnabled ? CalendarDate.today(now: introStart) : nil,
                                    endDate: introEndEnabled ? CalendarDate.today(now: introEnd) : nil,
                                    nominalDiscount: nominal, filter: filter, canary: canary))
    }

    // MARK: helpers

    private func load(_ action: () async -> ImportOutcome?) async {
        guard let outcome = await action() else { return }
        imported = outcome
        writeColumns = Set((model.config.importMapping?.targets ?? []).filter(\.writes).map { $0.column.uppercased() })
    }

    private func describe(_ kind: TargetKind) -> String {
        switch kind {
        case let .regularPrice(planType): return "regular price \(planType.rawValue)"
        case let .introPayUpFront(duration): return "intro, pay up front, \(PlanFormatting.durationLabel(duration))"
        case let .introPayAsYouGo(duration, periods): return "intro, pay as you go, \(PlanFormatting.durationLabel(duration)) × \(periods)"
        case .introFreeTrial: return "free trial"
        case let .promoPrice(code): return "promo \(code)"
        case .iapManualPrice: return "one-time purchase, manual price"
        }
    }

    private func applyPrefill() {
        guard let prefill else { return }
        tab = .intro
        selectedProducts = [prefill.subscriptionId]
        territoryText = prefill.territories.map(\.rawValue).sorted().joined(separator: ", ")
        introMode = prefill.mode
        introDuration = prefill.duration
        introPeriods = prefill.numberOfPeriods
        if let nominal = prefill.nominalDiscount {
            introNominal = "\(nominal * 100)"
            introPercent = "\((1 - nominal) * 100)"
        }
    }
}
