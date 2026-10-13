import SwiftUI
import Domain
import Catalog
import Policy
import Planner

/// Findings grouped by rule × product, one glass panel per group. "Create a repair plan" opens the New plan sheet
/// pre-filled, "Acknowledge without a fix…" needs a reason.
struct FindingsView: View {
    @Bindable var model: PlanningModel
    var onFix: (FixPrefill) -> Void
    @State private var ackGroup: FindingGroup?
    @State private var reason = ""
    @State private var expanded: Set<String> = []

    /// Rows shown before "Show all N".
    private static let previewCount = 3

    private var cellCount: Int { model.findingGroups.reduce(0) { $0 + $1.cellCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space4) {
            PurserScreenHeader("Findings") {
                Spacer()
                if !model.findingGroups.isEmpty {
                    Text("\(cellCount) cells in \(model.findingGroups.count) groups")
                        .font(PurserFont.callout)
                        .foregroundStyle(PurserColor.textSecondary)
                }
            }
            if model.findingGroups.isEmpty {
                ContentUnavailableView("No open findings", systemImage: "checkmark.seal",
                                       description: Text("The catalog is checked again after every sync."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    PurserGlassContainer {
                        VStack(spacing: PurserSpacing.space4) {
                            ForEach(model.findingGroups) { group in panel(group) }
                        }
                    }
                }
            }
        }
        .padding(PurserSpacing.space5)
        .sheet(item: $ackGroup) { group in ackSheet(group) }
    }

    private func panel(_ group: FindingGroup) -> some View {
        let isExpanded = expanded.contains(group.id)
        let shown = isExpanded ? group.findings : Array(group.findings.prefix(Self.previewCount))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PurserSpacing.space3) {
                PurserBadge(text: group.rule?.rawValue ?? group.type.rawValue, kind: .warning)
                Text(heading(group)).font(PurserFont.headline)
                Text("\(model.productName(group.productAscId)) · \(group.cellCount) cells")
                    .font(PurserFont.callout)
                    .foregroundStyle(PurserColor.textSecondary)
                Spacer()
                Button("Acknowledge without a fix…") {
                    reason = ""
                    ackGroup = group
                }
                .purserPlainButton()
                if let prefill = model.fixPrefill(for: group) {
                    Button("Create a repair plan") { onFix(prefill) }.purserButton()
                }
            }
            .padding(.bottom, PurserSpacing.space2)
            ForEach(shown, id: \.id) { finding in
                Divider().overlay(PurserColor.separator)
                HStack(alignment: .firstTextBaseline, spacing: PurserSpacing.space3) {
                    Text(finding.cell.territory?.rawValue ?? finding.cell.storageKey)
                        .font(PurserFont.identifier)
                        .foregroundStyle(PurserColor.textSecondary)
                        .frame(width: 48, alignment: .leading)
                    Text(finding.message).font(PurserFont.body).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, PurserSpacing.space2)
            }
            if group.findings.count > Self.previewCount {
                Divider().overlay(PurserColor.separator)
                Button(isExpanded ? "Show fewer" : "Show all \(group.findings.count)") {
                    if isExpanded { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }
                .font(PurserFont.callout)
                .purserPlainButton()
                .padding(.top, PurserSpacing.space2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .purserGlassPanel()
    }

    private func ackSheet(_ group: FindingGroup) -> some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space4) {
            Text("Acknowledge the finding without a fix").font(PurserFont.title2)
            Text("\(title(group)). The finding leaves the overview and the reason is saved to the audit.")
                .font(PurserFont.body)
                .foregroundStyle(PurserColor.textSecondary)
            VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                Text("Reason").font(PurserFont.headline).foregroundStyle(PurserColor.textSecondary)
                TextField("Reason", text: $reason, axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                Text("At least \(FindingAcknowledger.minimumReasonLength) characters.")
                    .font(PurserFont.footnote)
                    .foregroundStyle(PurserColor.textTertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { ackGroup = nil }
                    .keyboardShortcut(.cancelAction)
                    .purserButton()
                Button("Acknowledge finding") { Task { if await model.ack(group, reason: reason) { ackGroup = nil } } }
                    .keyboardShortcut(.defaultAction)
                    .purserButton(primary: true)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).count < FindingAcknowledger.minimumReasonLength)
            }
        }
        .padding(PurserSpacing.space5)
        .frame(width: 440)
    }

    /// "Intro ≥ regular price"; falls back to the finding type when the rule has no title.
    private func heading(_ group: FindingGroup) -> String {
        let topic = PlanFormatting.ruleTitle(group.rule)
        guard let first = topic.first else { return group.type.rawValue }
        return first.uppercased() + topic.dropFirst()
    }

    private func title(_ group: FindingGroup) -> String {
        let rule = group.rule?.rawValue ?? group.type.rawValue
        let topic = PlanFormatting.ruleTitle(group.rule)
        return "\(rule)\(topic.isEmpty ? "" : " \(topic)") · \(model.productName(group.productAscId)) · \(group.cellCount) cells"
    }
}
