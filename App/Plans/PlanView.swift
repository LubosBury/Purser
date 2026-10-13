import SwiftUI
import Domain
import Store
import Planner

/// Plan screen: title and state, summary figures, policy checks grouped by rule, the diff table and one action bar.
struct PlanView: View {
    @Bindable var model: PlanningModel
    let presentation: PlanPresentation
    var onBack: () -> Void
    @State private var rowFilter: RowFilter = .all
    @State private var ruleFilter: RuleID?
    @State private var showDetails = false
    @State private var messagesGroup: String?

    enum RowFilter: Hashable { case all, marked, excluded }

    /// Verdicts of one rule and severity, shown as one line of the checks panel.
    struct VerdictGroup: Identifiable {
        let rule: RuleID
        let severity: Severity
        let verdicts: [Verdict]
        var id: String { "\(rule.rawValue)|\(PlanFormatting.severityLabel(severity))" }
        var isBlock: Bool { if case .block = severity { return true } else { return false } }
    }

    private var plan: StoredPlan { presentation.plan }
    private var editable: Bool { plan.state == .draft || plan.state == .stale }

    private var visibleRows: [PlanDiffRow] {
        presentation.rows.filter { row in
            if rowFilter == .marked, !row.isMarked { return false }
            if let ruleFilter, !row.verdicts.contains(where: { $0.rule == ruleFilter }) { return false }
            return true
        }
    }

    private var verdictGroups: [VerdictGroup] {
        struct Key: Hashable { let rule: RuleID; let severity: Severity }
        return Dictionary(grouping: plan.verdicts) { Key(rule: $0.rule, severity: $0.severity) }
            .map { VerdictGroup(rule: $0.key.rule, severity: $0.key.severity, verdicts: $0.value) }
            .sorted { ($0.isBlock ? 0 : 1, $0.rule) < ($1.isBlock ? 0 : 1, $1.rule) }
    }

    var body: some View {
        PurserGlassContainer {
            VStack(alignment: .leading, spacing: PurserSpacing.space4) {
                header
                // Both panels have their own fixed height. `.fixedSize` around a DisclosureGroup here inflated the
                // screen's minimum height past the window and pushed the header and the action bar out of it.
                HStack(alignment: .top, spacing: PurserSpacing.space4) {
                    summaryPanel
                    checksPanel
                }
                checkSection
                filterRow
                if rowFilter == .excluded { excludedList } else { diffTable }
                actionBar
            }
            .padding(PurserSpacing.space5)
        }
        .onAppear { PlanOpenTrace.markAfterFrame("Plan screen first frame") }
    }

    // MARK: Header

    private var header: some View {
        PlanHeader(plan: plan, onBack: onBack) {
            if model.isWorking { ProgressView().controlSize(.small) }
            Button("Replan") { Task { await model.replan(planId: plan.id) } }
                .purserButton()
                .disabled(!editable || model.isWorking)
            Button("Cancel plan") { Task { await model.cancel(planId: plan.id) } }
                .purserButton()
                .disabled(!editable)
        }
    }

    // MARK: Summary

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space3) {
            HStack(alignment: .top, spacing: PurserSpacing.space4) {
                PurserStat(label: "Changes", value: "\(presentation.rows.count)")
                PurserStat(label: "Excluded", value: "\(plan.excluded.count)")
                PurserStat(label: "Effective from", value: presentation.nearestDate?.iso ?? "—")
                PurserStat(label: "Estimate", value: "\(plan.estimateMinutes) min")
            }
            Text("Built from snapshot #\(plan.baseSyncId) (age \(PlanFormatting.age(since: presentation.snapshotTakenAt))) · \(plan.estimateRequests) requests · confirmation C\(plan.confirmationLevel.rawValue)")
                .font(PurserFont.callout)
                .foregroundStyle(PurserColor.textSecondary)
            Button("Details") { showDetails = true }
                .font(PurserFont.callout)
                .purserPlainButton()
                .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                        Text("Key \(plan.binding.keyKind.rawValue) \(plan.binding.keyId)\(plan.binding.issuerId.map { " · issuer \($0)" } ?? "")")
                        Text("App \(plan.binding.appId) · \(plan.binding.bundleId) · build \(plan.appBuild)")
                        Text("Operace: \(presentation.opCounts.map { "\($0.op.rawValue) \($0.count)" }.joined(separator: " · "))")
                        Text("Plan \(plan.id)")
                    }
                    .font(PurserFont.identifier)
                    .foregroundStyle(PurserColor.textSecondary)
                    .textSelection(.enabled)
                    .padding(PurserSpacing.space4)
                }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .purserGlassPanel()
    }

    // MARK: Checks

    /// Height of one line of the checks panel, and how many lines show before the panel scrolls.
    private static let checkLineHeight = PurserSpacing.space8
    private static let visibleCheckLines = 3

    private var checksPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if verdictGroups.isEmpty {
                    Label("Checks without findings", systemImage: "checkmark")
                        .font(PurserFont.body)
                        .foregroundStyle(PurserColor.textSecondary)
                        .frame(height: Self.checkLineHeight)
                }
                ForEach(Array(verdictGroups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().overlay(PurserColor.separator) }
                    checkLine(group).frame(height: Self.checkLineHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.checkLineHeight * CGFloat(Self.visibleCheckLines))
        .purserGlassPanel(padding: PurserSpacing.space3)
    }

    private func checkLine(_ group: VerdictGroup) -> some View {
        HStack(spacing: PurserSpacing.space2) {
            PurserBadge(text: "\(PlanFormatting.severityWord(group.severity)) \(group.rule.rawValue)", kind: PlanFormatting.badgeKind(group.severity))
            Text(checkTitle(group)).font(PurserFont.body).lineLimit(1)
            Spacer(minLength: 0)
            Button("Reports") { messagesGroup = group.id }
                .font(PurserFont.callout)
                .purserPlainButton()
                .popover(isPresented: Binding(get: { messagesGroup == group.id }, set: { if !$0 { messagesGroup = nil } }), arrowEdge: .bottom) {
                    messages(group)
                }
            Button("Show") { show(group) }
                .font(PurserFont.callout)
                .purserPlainButton()
        }
    }

    /// Every verdict of the group in full; the panel line only has room for the rule's title.
    private func messages(_ group: VerdictGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                ForEach(Array(group.verdicts.enumerated()), id: \.offset) { _, verdict in
                    Text((verdict.cell.map { "\($0.storageKey): " } ?? "") + verdict.message + (verdict.riskClass.map { " · class: \($0)" } ?? ""))
                        .font(PurserFont.callout)
                        .foregroundStyle(PurserColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PurserSpacing.space4)
        }
        .frame(width: 440)
        .frame(maxHeight: 320)
    }

    private func checkTitle(_ group: VerdictGroup) -> String {
        let topic = PlanFormatting.ruleTitle(group.rule)
        let name = topic.isEmpty ? (group.verdicts.first?.message ?? "") : topic.prefix(1).uppercased() + topic.dropFirst()
        let cells = group.verdicts.filter { $0.cell != nil }.count
        guard cells > 0 else { return name }
        return "\(name) · \(cells) cells\(group.severity == .block(.cell) ? " excluded" : "")"
    }

    /// Cell blocks are not items, so they open the excluded list; everything else filters the diff table by rule.
    private func show(_ group: VerdictGroup) {
        if group.severity == .block(.cell) {
            ruleFilter = nil
            rowFilter = .excluded
        } else {
            rowFilter = .all
            ruleFilter = group.rule
        }
    }

    @ViewBuilder
    private var checkSection: some View {
        if case .importTable = presentation.spec.unwrapped {
            DisclosureGroup(presentation.checkDiffs.map { "Import check: \($0.count) differences (not written)" } ?? "Import check: calculating…") {
                ScrollView {
                    VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                        ForEach(presentation.checkDiffs ?? [], id: \.self) { diff in
                            Text("\(diff.column) · \(diff.cell.storageKey): import \(PlanFormatting.amount(diff.imported)) → point \(PlanFormatting.amount(diff.snapped)), live \(PlanFormatting.amount(diff.live))")
                                .font(PurserFont.identifier)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            .font(PurserFont.callout)
        }
    }

    // MARK: Diff

    private var filterRow: some View {
        HStack(spacing: PurserSpacing.space3) {
            Picker("Row filter", selection: $rowFilter) {
                Text("All \(presentation.rows.count)").tag(RowFilter.all)
                Text("To review \(presentation.rows.filter(\.isMarked).count)").tag(RowFilter.marked)
                Text("Excluded \(plan.excluded.count)").tag(RowFilter.excluded)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let ruleFilter {
                Button { self.ruleFilter = nil } label: { Label("Pravidlo \(ruleFilter.rawValue)", systemImage: "xmark") }
                    .controlSize(.small)
                    .purserButton()
                    .help("Clear the rule filter")
            }
            Spacer()
            if rowFilter != .excluded {
                Text("\(visibleRows.count) of \(presentation.rows.count) items")
                    .font(PurserFont.callout)
                    .foregroundStyle(PurserColor.textSecondary)
            }
        }
    }

    private var diffTable: some View {
        Table(visibleRows) {
            TableColumn("Product") { row in Text(model.productName(row.cell.productAscId)) }
            TableColumn("Territory") { row in Text(row.territory?.rawValue ?? "—") }
                .width(min: 60, ideal: 80)
            TableColumn("Currency") { row in Text(row.currency?.rawValue ?? "").foregroundStyle(PurserColor.textSecondary) }
                .width(50)
            TableColumn("Operation") { row in Text(row.op.rawValue).font(PurserFont.identifier).foregroundStyle(PurserColor.textSecondary) }
                .width(min: 70, ideal: 110)
            TableColumn("Before") { row in PurserFigure(row.before, color: PurserColor.textSecondary).help(row.before) }
            TableColumn("Po") { row in PurserFigure(row.after).help(row.after) }
            TableColumn("Change") { row in PurserFigure(PlanFormatting.signedPercent(row.deltaPercent), color: deltaColor(row.deltaPercent)) }
                .width(70)
            TableColumn("Effective from") { row in Text(row.date?.iso ?? "").font(PurserFont.figure) }
                .width(90)
            TableColumn("Detail") { row in Text(detail(row)).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary).help(detail(row)) }
            TableColumn("Flags") { row in flags(row) }
        }
        .purserTable()
    }

    /// Increases are `success`, decreases `warning`; the sign is always written.
    private func deltaColor(_ delta: Decimal?) -> Color {
        guard let delta, delta != 0 else { return PurserColor.textPrimary }
        return delta > 0 ? PurserColor.success : PurserColor.warning
    }

    /// Import snapping and the effective discount, for the plan kinds that have them.
    private func detail(_ row: PlanDiffRow) -> String {
        var parts: [String] = []
        if let imported = row.importedValue { parts.append("import \(imported) → point \(PlanFormatting.amount(row.afterPrice))") }
        if let discount = row.effectiveDiscount {
            parts.append("discount \(PlanFormatting.percent(discount)) · \(PlanFormatting.percent(row.percentOfRegular)) of regular")
        }
        return parts.joined(separator: " · ")
    }

    private func flags(_ row: PlanDiffRow) -> some View {
        HStack(spacing: PurserSpacing.space1) {
            ForEach(Array(row.verdicts.enumerated()), id: \.offset) { _, verdict in
                PurserBadge(text: "\(PlanFormatting.severityWord(verdict.severity)) \(verdict.rule.rawValue)", kind: PlanFormatting.badgeKind(verdict.severity))
                    .help(verdict.message)
            }
            ForEach(row.flags, id: \.self) { PurserBadge(text: $0.rawValue) }
        }
    }

    private var excludedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if plan.excluded.isEmpty {
                    Text("No cell is excluded.").font(PurserFont.body).foregroundStyle(PurserColor.textSecondary)
                }
                ForEach(Array(plan.excluded.enumerated()), id: \.element.storageKey) { index, cell in
                    if index > 0 { Divider().overlay(PurserColor.separator) }
                    HStack(alignment: .firstTextBaseline, spacing: PurserSpacing.space3) {
                        PurserBadge(text: "BLOCK", kind: .danger)
                        Text("\(model.productName(cell.productAscId)) · \(cell.territory?.rawValue ?? cell.storageKey)").font(PurserFont.body)
                        Text(excludedReason(cell))
                            .font(PurserFont.callout)
                            .foregroundStyle(PurserColor.textSecondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, PurserSpacing.space2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .purserGlassPanel()
    }

    private func excludedReason(_ cell: CellKey) -> String {
        let reasons = plan.verdicts.filter { $0.cell == cell && $0.severity == .block(.cell) }.map { "\($0.rule): \($0.message)" }
        return reasons.isEmpty ? "Depends on an excluded cell." : reasons.joined(separator: "; ")
    }

    // MARK: Actions

    private var actionBar: some View {
        ApplyControls(planId: plan.id, planState: plan.state, changeCount: presentation.rows.count, excludedCount: plan.excluded.count)
            .frame(maxWidth: .infinity, alignment: .leading)
            .purserGlassPanel(padding: PurserSpacing.space3)
    }
}

/// Back link, the plan's title and its state badge; `plan` is nil only when an opening plan is not in the list yet.
struct PlanHeader<Actions: View>: View {
    let plan: StoredPlan?
    var onBack: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space1) {
            Button(action: onBack) { Label("Plans", systemImage: "chevron.left") }
                .font(PurserFont.callout)
                .purserPlainButton()
            PurserScreenHeader(plan.map(PlanFormatting.title) ?? "Plan") {
                if let plan { PlanFormatting.stateBadge(plan) }
                Spacer()
                actions
            }
        }
    }
}

/// The Plan screen while a plan opens: what the plan list already knows, and a placeholder where the rows will be.
struct PlanLoadingView: View {
    let plan: StoredPlan?
    var onBack: () -> Void

    var body: some View {
        PurserGlassContainer {
            VStack(alignment: .leading, spacing: PurserSpacing.space4) {
                PlanHeader(plan: plan, onBack: onBack) {}
                HStack(alignment: .top, spacing: PurserSpacing.space4) {
                    PurserStat(label: "Changes", value: "…")
                    PurserStat(label: "Excluded", value: plan.map { "\($0.excluded.count)" } ?? "…")
                    PurserStat(label: "Effective from", value: "…")
                    PurserStat(label: "Estimate", value: plan.map { "\($0.estimateMinutes) min" } ?? "…")
                }
                .purserGlassPanel()
                VStack(spacing: PurserSpacing.space2) {
                    ProgressView()
                    Text("Loading plan items…").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .purserTableGround()
            }
            .padding(PurserSpacing.space5)
        }
        .onAppear { PlanOpenTrace.markAfterFrame("placeholder first frame") }
    }
}
