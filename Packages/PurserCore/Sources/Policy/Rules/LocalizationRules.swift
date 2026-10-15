import Foundation
import Domain
import Catalog

extension PlannedItem {
    var newText: SetLocalization? { if case let .setLocalization(s) = payload { return s } else { return nil } }
    /// The text rules N2-N4 judge: nil for a Live text written unchanged (carried over into a new version), which App Store
    /// Connect accepted already.
    var changedText: SetLocalization? {
        guard let text = newText, !LocalizationSemantics.carriesLiveText(text, before: before) else { return nil }
        return text
    }
    /// L3: the owner a createMetadataVersion item opens a new version for.
    var newVersionOwner: LocalizationOwner? { if case let .createMetadataVersion(owner) = payload { return owner } else { return nil } }
}

/// N1: the owner's version in preparation is waiting for review or in review; Purser never writes into it.
struct N1VersionInReviewRule: PlanRule {
    let id: RuleID = "N1"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            // L3: also the version cell of a createMetadataVersion item; no new version while one is in review.
            guard let owner = item.newText?.owner ?? item.newVersionOwner, let version = context.snapshot.pendingVersion(of: owner),
                  version.state.role == .inReview else { return nil }
            return .block(id, .cell, item.cell,
                          "Version \(version.number) of \(context.snapshot.ownerName(owner)) is \(version.state.rawValue); texts in review cannot change.")
        }
    }
}

/// N2: the locale must be one App Store Connect accepts (AppleConstants.localizationLocales, spike SL10n Q4).
struct N2LocaleRule: PlanRule {
    let id: RuleID = "N2"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let text = item.changedText, !AppleConstants.localizationLocales.contains(text.locale) else { return nil }
            return .block(id, .cell, item.cell, "“\(text.locale)” is not a locale App Store Connect accepts (for example en-US, cs, de-DE).")
        }
    }
}

/// N3: Apple's text limits (AppleConstants.localizationLimits; nil = no published limit, as for groups).
struct N3TextLengthRule: PlanRule {
    let id: RuleID = "N3"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let text = item.changedText, let limits = AppleConstants.localizationLimits[text.owner.kind] ?? nil else { return nil }
            var problems: [String] = []
            let name = text.text.name.count
            if name < limits.nameMin || name > limits.nameMax {
                problems.append("the name has \(Self.characters(name)), Apple allows \(limits.nameMin) to \(limits.nameMax)")
            }
            if let description = text.text.description, description.count > limits.descriptionMax {
                problems.append("the description has \(Self.characters(description.count)), Apple allows at most \(limits.descriptionMax)")
            }
            guard !problems.isEmpty else { return nil }
            return .block(id, .cell, item.cell, "\(text.locale): \(problems.joined(separator: "; ")).")
        }
    }

    static func characters(_ count: Int) -> String { count == 1 ? "1 character" : "\(count) characters" }
}

/// N4: a locale the target version does not have yet needs a name.
struct N4NewLocaleNameRule: PlanRule {
    let id: RuleID = "N4"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let text = item.changedText, Self.isNewLocale(item.before),
                  text.text.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .block(id, .cell, item.cell, "The new locale \(text.locale) needs a name.")
        }
    }

    /// No row in the version the text goes to: the version in preparation, or (L3) the live texts a new version copies.
    static func isNewLocale(_ before: CellState) -> Bool {
        guard case let .localization(live, pending, version) = before else { return false }
        return version != nil ? pending == nil : live == nil
    }
}

/// N5 (L3): a createMetadataVersion item opens a new version of an approved owner. C1, because the version cannot be
/// deleted through the API and customers see the new texts only after it is submitted in App Store Connect and approved.
struct N5NewVersionRule: PlanRule {
    let id: RuleID = "N5"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let owner = item.newVersionOwner else { return nil }
            return Verdict(rule: id, severity: .confirm(.c1), cell: item.cell, message: Self.message(context.snapshot.ownerName(owner)))
        }
    }

    static func message(_ ownerName: String) -> String {
        "Creates a new version of \(ownerName). The version cannot be deleted through the App Store Connect API, and customers see the new texts only after you submit it in App Store Connect and Apple approves it."
    }
}
