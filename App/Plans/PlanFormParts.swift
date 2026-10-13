import SwiftUI
import Domain
import Planner

/// Layout shared by every kind of the New plan sheet: numbered steps that scroll, and a fixed footer with the
/// plan's summary and the two actions.
struct PlanFormScaffold<Content: View, Footer: View>: View {
    private let content: Content
    private let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PurserSpacing.space5) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PurserSpacing.space5)
                    .padding(.bottom, PurserSpacing.space5)
            }
            Divider().overlay(PurserColor.separator)
            footer
                .padding(.horizontal, PurserSpacing.space5)
                .padding(.vertical, PurserSpacing.space4)
        }
    }
}

/// One step of a plan form: "2. Produkty", its controls and an optional hint. Steps that only appear for some
/// inputs carry no number.
struct PlanFormStep<Content: View>: View {
    private let number: Int?
    private let title: String
    private let hint: String?
    private let content: Content

    init(_ number: Int?, _ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.number = number
        self.title = title
        self.hint = hint
        self.content = content()
    }

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(nil, title, hint: hint, content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space2) {
            Text(number.map { "\($0). \(title)" } ?? title)
                .font(PurserFont.headline)
                .foregroundStyle(PurserColor.textSecondary)
            content
            if let hint { PlanFormHint(hint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled control inside a step (docs/design/components/Field.md): the label is always visible above it.
struct PlanFormField<Content: View>: View {
    private let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space1) {
            Text(label).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
            content.labelsHidden().textFieldStyle(.roundedBorder)
        }
    }
}

struct PlanFormHint: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(PurserFont.footnote)
            .foregroundStyle(PurserColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A group of checkboxes or rows on the quiet glass fill, as in the confirmation sheet.
struct PlanFormList<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space2) { content }
            .toggleStyle(.checkbox)
            .font(PurserFont.body)
            .padding(PurserSpacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PurserColor.glassFill, in: RoundedRectangle(cornerRadius: PurserRadius.radiusMd, style: .continuous))
    }
}

/// The pasted price table. It stays folded so the form reads as a few decisions; the row count says what is in it.
struct PlanPriceTableEditor: View {
    let title: String
    @Binding var text: String
    let hint: String
    var errors: [String] = []
    @State private var isOpen = false

    private var rowCount: Int { text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space1) {
            DisclosureGroup("\(title) · \(rowCount) rows", isExpanded: $isOpen) {
                TextEditor(text: $text)
                    .font(PurserFont.figure)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(PurserSpacing.space1)
                    .background(PurserColor.glassFill, in: RoundedRectangle(cornerRadius: PurserRadius.radiusSm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PurserRadius.radiusSm, style: .continuous).strokeBorder(PurserColor.borderControl))
                    .padding(.top, PurserSpacing.space1)
            }
            .font(PurserFont.body)
            PlanFormHint(hint)
            ForEach(errors, id: \.self) { PlanFormMessage($0, kind: .danger) }
        }
        // Errors point at rows, so the table opens when there are any.
        .onChange(of: errors.isEmpty) { _, isEmpty in if !isEmpty { isOpen = true } }
    }
}

/// An error or warning in words, with the status icon (never colour alone).
struct PlanFormMessage: View {
    private let text: String
    private let kind: PurserBadge.Kind

    init(_ text: String, kind: PurserBadge.Kind) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(PurserFont.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var symbol: String {
        switch kind {
        case .danger: return "xmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .success: return "checkmark"
        case .info, .neutral: return "info.circle"
        }
    }

    private var color: Color {
        switch kind {
        case .danger: return PurserColor.danger
        case .warning: return PurserColor.warning
        case .success: return PurserColor.success
        case .info: return PurserColor.info
        case .neutral: return PurserColor.textSecondary
        }
    }
}

/// Verdicts of the draft being built, one line each: "R3: …".
struct PlanFormVerdicts: View {
    let verdicts: [Verdict]

    var body: some View {
        ForEach(Array(verdicts.enumerated()), id: \.offset) { _, verdict in
            PlanFormMessage("\(verdict.rule.rawValue): \(verdict.message)", kind: PlanFormatting.badgeKind(verdict.severity))
        }
    }
}

/// Footer of a plan form: what the plan would contain right now, then Cancel and the one primary action.
struct PlanFormFooter: View {
    var draft: PlanDraft?
    var error: String?
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    private func count(_ matches: (Severity) -> Bool) -> Int { (draft?.verdicts ?? []).filter { matches($0.severity) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space2) {
            if let error { PlanFormMessage(error, kind: .danger) }
            HStack(spacing: PurserSpacing.space2) {
                if let draft {
                    let blocks = count { if case .block = $0 { return true } else { return false } }
                    let warnings = count { $0 == .warn }
                    if blocks > 0 { PurserBadge(text: "BLOCK \(blocks)", kind: .danger) }
                    if warnings > 0 { PurserBadge(text: "WARN \(warnings)", kind: .warning) }
                    Text(summary(draft))
                        .font(PurserFont.callout)
                        .foregroundStyle(PurserColor.textSecondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .purserButton()
                Button("Build plan", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .purserButton(primary: true)
                    .disabled(!canSave)
            }
        }
    }

    private func summary(_ draft: PlanDraft) -> String {
        var parts = ["\(draft.items.count) changes"]
        if !draft.excluded.isEmpty { parts.append("\(draft.excluded.count) cells excluded") }
        parts.append("asi \(draft.estimate.minutes) min")
        parts.append("confirmation C\(draft.confirmationLevel.rawValue)")
        return parts.joined(separator: " · ")
    }
}

extension PlanFormatting {
    static func modeLabel(_ mode: OfferMode) -> String {
        switch mode {
        case .freeTrial: return "Free trial"
        case .payUpFront: return "Pay up front"
        case .payAsYouGo: return "Pay as you go"
        }
    }

    static func durationLabel(_ duration: OfferDuration) -> String {
        switch duration {
        case .threeDays: return "3 days"
        case .oneWeek: return "1 week"
        case .twoWeeks: return "2 weeks"
        case .oneMonth: return "1 month"
        case .twoMonths: return "2 months"
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        case .oneYear: return "1 year"
        }
    }
}
