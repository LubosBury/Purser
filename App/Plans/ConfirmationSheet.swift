import SwiftUI
import Domain
import Executor

/// C0/C1/C2 confirmation (spec §7) over the fresh verdicts, with the workspace banner on top.
struct ConfirmationSheet: View {
    let request: ConfirmationRequest
    let config: WorkspaceConfig
    /// Items the apply will write; the title states the number.
    let changeCount: Int
    let onAnswer: (ConfirmationResponse) -> Void

    @State private var acknowledged = false
    @State private var typedName = ""
    @State private var reason = ""
    @State private var checked: Set<String> = []

    private var response: ConfirmationResponse {
        ConfirmationResponse(accepted: true, acknowledgedExclusions: acknowledged, typedAppName: typedName, reason: reason,
                             checkedRiskClasses: checked)
    }

    private var problems: [String] { ConfirmationValidator.problems(request: request, response: response) }

    /// The validator's open problems in the user's words; the validator's own text goes to the audit.
    private var remainingSteps: [String] {
        var steps: [String] = []
        if !request.excluded.isEmpty, !acknowledged { steps.append("Excluded cells still need to be acknowledged.") }
        if request.level >= .c1, typedName != request.appName { steps.append("The app name still needs to be typed.") }
        if request.level >= .c2 {
            if reason.trimmingCharacters(in: .whitespacesAndNewlines).count < AppleConstants.c2MinReasonLength {
                steps.append("The reason must have at least \(AppleConstants.c2MinReasonLength) characters.")
            }
            let missing = Set(request.riskClasses.keys).subtracting(checked).sorted()
            if !missing.isEmpty { steps.append("Still to confirm: \(missing.joined(separator: ", ")).") }
        }
        return steps.isEmpty ? problems : steps
    }

    private var levelNote: String {
        switch request.level {
        case .c0: return "Prices will be written to App Store Connect."
        case .c1: return "Prices will be written to App Store Connect in a production workspace."
        case .c2: return "The plan contains risky changes. Prices will be written to App Store Connect."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceBanner(config: config)
            VStack(alignment: .leading, spacing: PurserSpacing.space4) {
                Text("Apply \(changeCount) changes in \(request.appName)").font(PurserFont.title2)
                Text(levelNote + (request.excluded.isEmpty ? "" : " \(request.excluded.count) excluded cells stay unchanged."))
                    .font(PurserFont.body)
                    .foregroundStyle(PurserColor.textSecondary)
                if request.verdictHashChanged {
                    Label("The checks have changed since the draft was built. Go through them again.", systemImage: "exclamationmark.triangle")
                        .font(PurserFont.body)
                        .foregroundStyle(PurserColor.warning)
                }
                if !request.verdicts.isEmpty { verdictList }
                if !request.excluded.isEmpty || request.level >= .c2 { checklist }
                if request.level >= .c1 {
                    field("App name", hint: "Type \(request.appName) to confirm the write to production.") {
                        TextField("App name", text: $typedName, prompt: Text(request.appName))
                    }
                }
                if request.level >= .c2 {
                    field("Reason", hint: "At least \(AppleConstants.c2MinReasonLength) characters. Saved to the audit.") {
                        TextField("Reason", text: $reason, axis: .vertical).lineLimit(3...5)
                    }
                }
                // The disabled primary says why: every open step is listed above the buttons.
                ForEach(remainingSteps, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(PurserFont.callout)
                        .foregroundStyle(PurserColor.warning)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        onAnswer(ConfirmationResponse(accepted: false, acknowledgedExclusions: false, typedAppName: nil, reason: nil, checkedRiskClasses: []))
                    }
                    .keyboardShortcut(.cancelAction)
                    .purserButton()
                    Button("Apply with Touch ID") { onAnswer(response) }
                        .purserButton(primary: true)
                        .disabled(!problems.isEmpty)
                }
            }
            .padding(PurserSpacing.space5)
        }
        .frame(width: 440)
    }

    private var verdictList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                ForEach(Array(request.verdicts.enumerated()), id: \.offset) { _, verdict in
                    HStack(alignment: .firstTextBaseline, spacing: PurserSpacing.space2) {
                        Text(verdict.rule.rawValue).font(PurserFont.identifier).frame(width: 36, alignment: .leading)
                        Text(verdict.message).font(PurserFont.callout)
                    }
                    .foregroundStyle(PurserColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space2) {
            if !request.excluded.isEmpty {
                Toggle("I acknowledge \(request.excluded.count) excluded cells", isOn: $acknowledged)
                    .help(request.excluded.map(\.storageKey).joined(separator: "\n"))
            }
            if request.level >= .c2 {
                ForEach(request.riskClasses.keys.sorted(), id: \.self) { riskClass in
                    Toggle("\(riskClass) · \(request.riskClasses[riskClass] ?? 0) cells", isOn: Binding(
                        get: { checked.contains(riskClass) },
                        set: { isOn in if isOn { checked.insert(riskClass) } else { checked.remove(riskClass) } }))
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(PurserFont.body)
        .padding(PurserSpacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PurserColor.glassFill, in: RoundedRectangle(cornerRadius: PurserRadius.radiusMd, style: .continuous))
    }

    private func field<Content: View>(_ label: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space1) {
            Text(label).font(PurserFont.headline).foregroundStyle(PurserColor.textSecondary)
            content().labelsHidden().textFieldStyle(.roundedBorder)
            Text(hint).font(PurserFont.footnote).foregroundStyle(PurserColor.textTertiary)
        }
    }
}
