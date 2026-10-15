import SwiftUI
import Catalog
import Domain
import Executor
import Planner

/// Clones subscriptions and one-time purchases for an A/B test (docs/specs/2026-10-14-localizations-and-cloning-design.md §6).
/// A clone gets its source's attributes, availability, texts and review screenshot in one run with one Touch ID; its
/// prices and offers follow as Draft plans after a sync. A Product ID is burned forever once it is created, so the sheet
/// shows exactly what will be sent and asks for an acknowledgement first.
struct CloneProductsSheet: View {
    let session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable, Hashable {
        let id = UUID()
        var source: LocalizationOwner
        var productId: String
        var name: String
    }

    enum GroupChoice: String, CaseIterable, Identifiable {
        case source = "Source group", new = "New group"
        var id: String { rawValue }
    }

    enum LevelChoice: String, CaseIterable, Identifiable {
        case source = "Source level", end = "End of the group"
        var id: String { rawValue }
    }

    /// What the last run cloned, kept for "Prepare price drafts".
    struct Cloned: Equatable {
        var created: [String: String]
        var copy: CloneCopy
        var suffix: String
    }

    @State private var rows: [Row]
    @State private var suffix = ""
    @State private var appliedSuffix = ""
    @State private var groupChoice: GroupChoice = .source
    @State private var newGroupName = ""
    @State private var levelChoice: LevelChoice = .source
    @State private var copy = CloneCopy()
    @State private var preview: ClonePreview?
    @State private var acknowledged = false
    @State private var report: CloneReport?
    @State private var cloned: Cloned?
    @State private var drafts: CloneDraftOutcome?
    @State private var isWorking = false
    @State private var message: String?

    init(session: WorkspaceSession, sources: [LocalizationOwner]) {
        self.session = session
        _rows = State(initialValue: sources.compactMap { Self.row(for: $0, suffix: "", snapshot: session.snapshot) })
    }

    private static func sourceInfo(_ owner: LocalizationOwner, _ snapshot: CatalogSnapshot?) -> (productId: String, name: String)? {
        switch owner.kind {
        case .subscription: return snapshot?.subscriptions[owner.ascId].map { ($0.productId, $0.name) }
        case .iap: return snapshot?.iaps[owner.ascId].map { ($0.productId, $0.name) }
        case .group: return nil
        }
    }

    private static func row(for owner: LocalizationOwner, suffix: String, snapshot: CatalogSnapshot?) -> Row? {
        guard let info = sourceInfo(owner, snapshot) else { return nil }
        return Row(source: owner, productId: info.productId + suffix, name: info.name + suffix)
    }

    /// The group and level choices are only in the request while the Target step shows them (it needs a subscription), so a
    /// choice hidden by removing the last subscription cannot stay in it.
    private var request: CloneRequest {
        CloneRequest(items: rows.map { CloneItem(source: $0.source, productId: $0.productId.trimmingCharacters(in: .whitespaces),
                                                 name: $0.name.trimmingCharacters(in: .whitespaces)) },
                     group: hasSubscriptions && groupChoice == .new ? .newGroup(name: newGroupName.trimmingCharacters(in: .whitespaces)) : .sourceGroup,
                     level: hasSubscriptions && levelChoice == .end ? .end : .sameAsSource, copy: copy, offerCodeSuffix: suffix)
    }

    private var problems: [String] {
        guard let snapshot = session.snapshot else { return ["The catalog is empty; run a sync first."] }
        return ClonePlanner.problems(request, snapshot: snapshot)
    }

    private var hasSubscriptions: Bool { rows.contains { $0.source.kind == .subscription } }
    /// The sync did not finish or a Draft failed: preparing the drafts again is what is left to do.
    private var needsDraftRetry: Bool {
        guard let drafts else { return false }
        return drafts.syncProblem != nil || drafts.drafts.contains { $0.error != nil }
    }
    private var canClone: Bool { !isWorking && problems.isEmpty && acknowledged && !(preview?.writable.isEmpty ?? true) }

    /// Step numbers shift by one when there is no subscription and so no Target step.
    private func stepNumber(_ number: Int) -> Int { hasSubscriptions ? number + 1 : number }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceBanner(config: session.config)
            Text("Clone products").font(PurserFont.title2).padding(PurserSpacing.space5)
            PlanFormScaffold {
                if hasSubscriptions { targetStep }
                idStep
                copyStep
                if !problems.isEmpty && !rows.isEmpty {
                    VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                        ForEach(problems, id: \.self) { PlanFormMessage($0, kind: .danger) }
                    }
                }
                summaryStep
                resultStep
                draftsStep
                if let message { PlanFormMessage(message, kind: .neutral) }
            } footer: {
                footer
            }
        }
        // The ideal height, not the content, sizes the sheet: a long result cannot make it taller than the screen (the steps
        // scroll). The minimum is that of the New products sheet.
        .frame(minWidth: 820, minHeight: 620, idealHeight: 660)
        .onChange(of: request) { _, _ in
            preview = nil
            acknowledged = false
        }
        .onChange(of: suffix) { _, newSuffix in applySuffix(newSuffix) }
    }

    // MARK: Steps

    private var targetStep: some View {
        PlanFormStep(1, "Target", hint: groupChoice == .new
            ? "The new group gets the texts of the source group; its subscriptions keep the order of their sources' levels."
            : "Variants of an A/B test stay in one group: a customer holds one subscription of a group at a time.") {
            HStack(alignment: .top, spacing: PurserSpacing.space4) {
                PlanFormField("Group") {
                    Picker("Group", selection: $groupChoice) { ForEach(GroupChoice.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .fixedSize()
                }
                if groupChoice == .new {
                    PlanFormField("New group name") { TextField("New group name", text: $newGroupName) }
                }
                PlanFormField("Level") {
                    Picker("Level", selection: $levelChoice) { ForEach(LevelChoice.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(groupChoice == .new)
                }
            }
        }
    }

    private var idStep: some View {
        PlanFormStep(stepNumber(1), "New Product IDs",
                     hint: "Apple never lets a Product ID be used again, not even after the product is deleted, and Purser cannot see deleted products. The suffix also goes to the codes of copied promotional offers.") {
            PlanFormField("Suffix") { TextField("Suffix", text: $suffix, prompt: Text("e.g. _AB3")).font(PurserFont.figure) }
            // One header row keeps the labels visible once the fields are filled in (docs/design/components/Field.md).
            Grid(alignment: .leading, horizontalSpacing: PurserSpacing.space2, verticalSpacing: PurserSpacing.space2) {
                if !rows.isEmpty {
                    GridRow {
                        Text("Source")
                        Text("").accessibilityHidden(true)      // above the arrow
                        Text("Product ID")
                        Text("Reference name")
                        Text("").accessibilityHidden(true)      // above the remove button
                    }
                    .font(PurserFont.callout)
                    .foregroundStyle(PurserColor.textSecondary)
                }
                ForEach($rows) { $row in
                    GridRow {
                        Text(sourceLabel(row.source))
                            .font(PurserFont.identifier)
                            .foregroundStyle(PurserColor.textSecondary)
                            .lineLimit(1)
                        Image(systemName: "arrow.right").foregroundStyle(PurserColor.textTertiary).accessibilityHidden(true)
                        TextField("Product ID", text: $row.productId).font(PurserFont.figure).frame(maxWidth: .infinity)
                        TextField("Reference name", text: $row.name).frame(maxWidth: .infinity)
                        Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(sourceLabel(row.source))")
                            .help("Remove \(sourceLabel(row.source))")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            Menu("Add product") {
                ForEach(candidates, id: \.self) { owner in
                    Button(sourceLabel(owner)) {
                        if let row = Self.row(for: owner, suffix: suffix, snapshot: session.snapshot) { rows.append(row) }
                    }
                }
            }
            .fixedSize()
            .disabled(candidates.isEmpty || isWorking)
        }
    }

    private var copyStep: some View {
        PlanFormStep(stepNumber(2), "What to copy",
                     hint: "The clone itself never writes prices or offers: they come as Draft plans you review and apply, or cancel and replace with new prices. Never copied: the MONTHLY plan type, scheduled price changes and future one-time purchase prices.") {
            PlanFormList {
                Toggle("Localizations (names and descriptions)", isOn: $copy.localizations)
                Toggle("Review screenshot", isOn: $copy.reviewScreenshot)
                Toggle("Current prices, as a Draft", isOn: $copy.prices)
                Toggle("Introductory offers, as Drafts", isOn: $copy.introOffers)
                Toggle("Promotional offers, as Drafts", isOn: $copy.promoOffers)
            }
        }
    }

    @ViewBuilder private var summaryStep: some View {
        if let preview {
            let writable = preview.writable.count
            PlanFormStep(stepNumber(3), preview.steps.isEmpty ? "Everything is already in App Store Connect"
                         : writable == 0 ? "Nothing can be written now" : "Summary: \(writable) steps") {
                if preview.steps.isEmpty {
                    PlanFormHint("Nothing will be written. Prepare price drafts builds the Drafts the clones do not have yet and leaves the ones that exist alone.")
                } else {
                    PlanFormList {
                        ForEach(Array(preview.steps.enumerated()), id: \.offset) { _, step in
                            if let reason = preview.blocked[step] {
                                // Blocked steps are never sent and are not part of the Touch ID prompt.
                                HStack(alignment: .firstTextBaseline, spacing: PurserSpacing.space2) {
                                    Text(describe(step))
                                    Spacer()
                                    Text(reason).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                                    PurserBadge(text: "Blocked", kind: .danger)
                                }
                            } else {
                                Text(describe(step))
                            }
                        }
                        if writable > 0 {
                            Divider().overlay(PurserColor.separator)
                            Toggle("I understand that a Product ID can never be used again once created, not even after the product is deleted.",
                                   isOn: $acknowledged)
                        }
                    }
                    if writable == 0 {
                        PlanFormHint("Nothing will be written. Clear the blocked steps in App Store Connect, then check again. Prepare price drafts builds the Drafts the clones do not have yet.")
                    }
                }
            }
        }
    }

    @ViewBuilder private var resultStep: some View {
        if let report, !report.steps.isEmpty {
            PlanFormStep("Result") {
                PlanFormList {
                    ForEach(Array(report.steps.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: PurserSpacing.space2) {
                            Text(describe(entry.step))
                            Spacer()
                            Text(CreateProductsSheet.detail(entry.outcome)).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                            CreateProductsSheet.badge(entry.outcome)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var draftsStep: some View {
        if let drafts {
            PlanFormStep("Price drafts", hint: "Apply them in this order on the Plans screen: the regular prices first, then the offers.") {
                if let problem = drafts.syncProblem {
                    PlanFormMessage("No drafts were prepared: \(problem)", kind: .warning)
                } else if !drafts.drafts.isEmpty {
                    PlanFormList {
                        ForEach(drafts.drafts, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: PurserSpacing.space2) {
                                Text(line.title)
                                Spacer()
                                if let error = line.error {
                                    Text(error).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                                    PurserBadge(text: "Failed", kind: .danger)
                                } else {
                                    if let note = line.note { Text(note).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary) }
                                    planBadge(line)
                                }
                            }
                        }
                    }
                } else {
                    PlanFormMessage("No drafts were built.", kind: .neutral)
                }
            }
            if !drafts.notes.isEmpty {
                PlanFormStep("Not copied", hint: "Purser writes UPFRONT prices only and gives a clone the prices in force today; plan these by hand once the clone's first prices are applied.") {
                    ForEach(drafts.notes, id: \.self) { PlanFormMessage($0, kind: .warning) }
                }
            }
        }
    }

    /// The state of the plan a line names. A Draft keeps the Draft badge; a plan with the draft's title that is no longer a
    /// Draft ("Plan already exists", or a Draft applied since) shows its state as the Plans screen does. A plan the
    /// planning model does not list (yet) gets no badge rather than a state it may not have.
    @ViewBuilder private func planBadge(_ line: CloneDraftOutcome.Line) -> some View {
        if let plan = line.planId.flatMap({ id in session.planning.plans.first { $0.id == id } }) {
            if plan.state == .draft {
                PurserBadge(text: "Draft", kind: .neutral, icon: "pencil")
            } else {
                PlanFormatting.stateBadge(plan)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: PurserSpacing.space2) {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .purserButton()
                .disabled(isWorking)
            // One primary at a time: the read-only check, then the write it prepared, or the drafts again. Preparing the
            // drafts again is always safe (a Draft that exists is left alone), so it is offered after every run; it is the
            // primary one when a Draft failed or the sync did not finish.
            if needsDraftRetry {
                Button("Prepare price drafts") { Task { await prepareDrafts() } }
                    .purserButton(primary: true)
                    .disabled(isWorking)
            } else if let preview, !preview.writable.isEmpty {
                Button("Check again") { Task { await check() } }
                    .purserButton()
                    .disabled(isWorking || !problems.isEmpty)
                Button("Clone with Touch ID") { Task { await clone() } }
                    .purserButton(primary: true)
                    .disabled(!canClone)
            } else if preview != nil {
                Button("Check again") { Task { await check() } }
                    .purserButton()
                    .disabled(isWorking || !problems.isEmpty)
                // Nothing writable is missing, so nothing is written here; if something is missing again, the steps are shown
                // to be confirmed (see `prepareExisting`). A blocked step stays blocked until the owner clears it.
                Button("Prepare price drafts") { Task { await prepareExisting() } }
                    .purserButton(primary: true)
                    .disabled(isWorking || !problems.isEmpty)
            } else {
                if cloned?.created.isEmpty == false {
                    Button("Prepare price drafts") { Task { await prepareDrafts() } }
                        .purserButton()
                        .disabled(isWorking)
                }
                Button("Check") { Task { await check() } }
                    .keyboardShortcut(.defaultAction)
                    .purserButton(primary: true)
                    .disabled(isWorking || !problems.isEmpty || rows.isEmpty)
            }
        }
    }

    // MARK: Actions

    /// Reads what the app has now and shows the steps still needed. Sends nothing but GETs.
    private func check() async {
        guard let snapshot = session.snapshot else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            preview = try await session.makeProductCreator().previewClone(request, snapshot: snapshot)
        } catch {
            message = "The check failed: \(Self.errorText(error))"
        }
    }

    /// The clone (one Touch ID, none when nothing is missing), then the sync and the price drafts.
    private func clone() async {
        guard let snapshot = session.snapshot else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        let request = self.request
        do {
            // The run stays marked through the drafts below; `prepareDrafts` releases the claim.
            let claim = try session.productRuns.claim(.clone)
            let result: CloneReport
            do {
                result = try await session.makeProductCreator().clone(request, snapshot: snapshot, holding: claim)
            } catch {
                claim.release()
                throw error
            }
            report = result
            preview = nil
            acknowledged = false
            if result.steps.contains(where: { if case .failed = $0.outcome { return true } else { return false } }) {
                message = "Some steps failed. Fix the cause and press Check: the next run adds only what is missing."
            }
            cloned = Cloned(created: result.created, copy: request.copy, suffix: request.offerCodeSuffix)
            await prepareDrafts(holding: claim)
        } catch {
            message = "The clone failed: \(Self.errorText(error))"
        }
    }

    /// The Drafts of every clone of the last run. Safe to repeat, also after the sheet was closed and opened again: a Draft
    /// that exists (in the plans, whoever made it) is reported and not built twice, and one that failed is built now.
    /// Refused while another clone, or the drafts of one, is in progress (ProductRuns). `claim` is the one of the clone this
    /// follows; it is released when the drafts are done.
    private func prepareDrafts(holding claim: ProductRunClaim? = nil) async {
        guard let cloned, !cloned.created.isEmpty else {
            claim?.release()
            return
        }
        isWorking = true
        defer { isWorking = false }
        if let claim {
            drafts = await session.prepareCloneDrafts(created: cloned.created, copy: cloned.copy, offerCodeSuffix: cloned.suffix, holding: claim)
            return
        }
        do {
            drafts = try await session.prepareCloneDrafts(created: cloned.created, copy: cloned.copy, offerCodeSuffix: cloned.suffix)
        } catch {
            message = "The drafts were not prepared: \(Self.errorText(error))"
        }
    }

    /// "Prepare price drafts" after a check that found nothing missing. It reads the request again first: when something
    /// is missing now, the steps are shown and the acknowledgement is asked for again, so this button never writes.
    private func prepareExisting() async {
        guard let snapshot = session.snapshot else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        let request = self.request
        do {
            switch try await session.cloneState(request, snapshot: snapshot) {
            case let .missing(missing):
                preview = missing
                acknowledged = false
                message = "Something is missing in App Store Connect now, so nothing was prepared. Check the steps and confirm them to clone."
            case let .complete(created):
                cloned = Cloned(created: created, copy: request.copy, suffix: request.offerCodeSuffix)
                await prepareDrafts()
            }
        } catch {
            message = "The check failed: \(Self.errorText(error))"
        }
    }

    /// A row keeps what the user typed; only a value that is still the prefill follows the new suffix.
    private func applySuffix(_ newSuffix: String) {
        for index in rows.indices {
            guard let info = Self.sourceInfo(rows[index].source, session.snapshot) else { continue }
            if rows[index].productId == info.productId + appliedSuffix { rows[index].productId = info.productId + newSuffix }
            if rows[index].name == info.name + appliedSuffix { rows[index].name = info.name + newSuffix }
        }
        appliedSuffix = newSuffix
    }

    // MARK: Text

    private var candidates: [LocalizationOwner] {
        guard let snapshot = session.snapshot else { return [] }
        let chosen = Set(rows.map(\.source))
        let subscriptions = snapshot.subscriptions.values.sorted { ($0.groupName, $0.name) < ($1.groupName, $1.name) }
            .map { LocalizationOwner.subscription($0.ascId) }
        let purchases = snapshot.iaps.values.sorted { $0.name < $1.name }.map { LocalizationOwner.iap($0.ascId) }
        return (subscriptions + purchases).filter { !chosen.contains($0) }
    }

    private func sourceLabel(_ owner: LocalizationOwner) -> String {
        Self.sourceInfo(owner, session.snapshot)?.productId ?? owner.ascId
    }

    private func describe(_ step: CloneStep) -> String {
        switch step {
        case let .group(name): return "Group “\(name)”"
        case let .groupLocalization(locale): return "Text \(locale) of the new group"
        case let .product(item):
            return "\(item.source.kind == .iap ? "One-time purchase" : "Subscription") \(item.productId), a copy of \(sourceLabel(item.source))"
        case let .availability(productId): return "Availability of \(productId) as its source has it"
        case let .localization(productId, locale): return "Text \(locale) of \(productId)"
        case let .reviewScreenshot(productId): return "Review screenshot of \(productId)"
        }
    }

    static func errorText(_ error: Error) -> String {
        switch error as? ProductCreationError {
        case let .invalid(problems)?: return problems.joined(separator: " ")
        case let .bindingMismatch(detail)?: return "the workspace no longer matches the app in App Store Connect (\(detail))"
        case let .anotherRunInProgress(kind)?: return kind.waitMessage
        case nil: return error.localizedDescription
        }
    }
}
