import Foundation
import Domain
import Catalog

extension PlanBuilder {
    /// L10N: one SET_TEXT item per owner and locale whose text differs from the version in preparation. An empty field
    /// keeps the current text (L-D3); a text is never removed. An owner with a live version and none in preparation goes to
    /// addTextsInNewVersion; an owner without any version gets BLOCK·PLAN.
    mutating func addLocalization(_ spec: LocalizationPlanSpec) {
        var counts: [CellKey: Int] = [:]
        for edit in spec.edits { counts[.localization(owner: edit.owner, locale: edit.locale), default: 0] += 1 }
        let repeated = Set(counts.filter { $0.value > 1 }.keys)
        for cell in repeated.sorted(by: { $0.storageKey < $1.storageKey }) {
            guard case let .localization(owner, locale) = cell else { continue }
            verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.cell), cell: cell,
                                    message: "\(snapshot.ownerName(owner)) \(locale) is in the plan more than once."))
        }
        let edits = spec.edits.filter { !repeated.contains(.localization(owner: $0.owner, locale: $0.locale)) }
        for (owner, ownerEdits) in Dictionary(grouping: edits, by: \.owner).sorted(by: { $0.key < $1.key }) {
            guard ownerExists(owner) else {
                verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: nil,
                                        message: "\(owner.kind == .group ? "The subscription group" : "The product") \(owner.ascId) is not in the catalog."))
                continue
            }
            let sorted = ownerEdits.sorted { $0.locale < $1.locale }.filter { validate($0) }
            guard let pending = snapshot.pendingVersion(of: owner) else {
                if let live = snapshot.liveVersion(of: owner) {
                    // The only call into the new-version path (PlanBuilder+NewVersion.swift).
                    addTextsInNewVersion(owner: owner, live: live, edits: sorted)
                } else {
                    verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: nil,
                                            message: "\(snapshot.ownerName(owner)) has no version with texts in App Store Connect; sync the catalog first."))
                }
                continue
            }
            for edit in sorted { addText(edit, pending: pending) }
        }
    }

    /// A row that sets a field its owner kind does not have gets BLOCK·CELL; false then. Runs for every owner, before the
    /// row is routed to the version in preparation or to the new-version path.
    private mutating func validate(_ edit: LocalizationEdit) -> Bool {
        let isGroup = edit.owner.kind == .group
        let message: String
        if isGroup, Self.value(edit.description) != nil {
            message = "A subscription group has no description; put the text into the custom app name."
        } else if !isGroup, Self.value(edit.customAppName) != nil {
            message = "Only a subscription group has a custom app name."
        } else {
            return true
        }
        verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.cell),
                                cell: .localization(owner: edit.owner, locale: edit.locale), message: message))
        return false
    }

    private mutating func addText(_ edit: LocalizationEdit, pending: MetadataVersion) {
        let owner = edit.owner
        let cell = CellKey.localization(owner: owner, locale: edit.locale)
        let current = snapshot.localization(owner, locale: edit.locale, versionId: pending.ascId)
        if current == nil, !Self.hasText(edit) { return }
        let desired = Self.desiredText(for: edit, current: current?.text)
        if let current, current.text == desired { return }
        let before = snapshot.cellState(cell, on: today)
        var live: LocalizationRow?
        if case let .localization(row, _, _) = before { live = row }
        let row = LocalizationRow(ascId: current?.ascId ?? PlannedRow.ascId, owner: owner, versionId: pending.ascId,
                                  locale: edit.locale, text: desired)
        let payload = SetLocalization(owner: owner, locale: edit.locale, text: desired,
                                      localizationId: current?.ascId, versionId: current == nil ? pending.ascId : nil)
        sink.add(cell, .setLocalization(payload), before: before,
                 target: .localization(live: live, pending: row, pendingVersion: pending), rules: ["N1", "N2", "N3", "N4"])
    }

    func ownerExists(_ owner: LocalizationOwner) -> Bool {
        switch owner.kind {
        case .subscription: return snapshot.subscriptions[owner.ascId] != nil
        case .iap: return snapshot.iaps[owner.ascId] != nil
        case .group: return snapshot.groups[owner.ascId] != nil
        }
    }

    /// The text the row asks for: each field the row leaves empty keeps the current text (L-D3); a group has a custom app
    /// name and no description, any other owner the reverse. Expects a row that passed `validate`.
    static func desiredText(for edit: LocalizationEdit, current: LocalizationText?) -> LocalizationText {
        let isGroup = edit.owner.kind == .group
        return LocalizationText(
            name: value(edit.name) ?? current?.name ?? "",
            description: isGroup ? nil : (value(edit.description) ?? current?.description),
            customAppName: isGroup ? (value(edit.customAppName) ?? current?.customAppName) : nil)
    }

    /// The trimmed text, or nil for a missing or blank cell.
    static func value(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func hasText(_ edit: LocalizationEdit) -> Bool {
        [edit.name, edit.description, edit.customAppName].contains { value($0) != nil }
    }
}
