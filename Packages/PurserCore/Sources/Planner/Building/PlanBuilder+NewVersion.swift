import Foundation
import Domain
import Catalog

extension PlanBuilder {
    /// L3 (rule N5): an owner with a Live version and no version in preparation gets one createMetadataVersion item, and every
    /// text item of the owner depends on it. The texts carry no ids: the version and its rows exist only after the write, so
    /// the Executor finds them by reading. A text item's `before` is its cell in the snapshot (rule A4); the version is
    /// a cell of its own. A row without text, or with exactly the live text (an unedited export row), gives nothing.
    /// Expects edits that passed `addLocalization`'s field validation.
    mutating func addTextsInNewVersion(owner: LocalizationOwner, live: MetadataVersion, edits: [LocalizationEdit]) {
        addTextsInNewVersion(owner: owner, live: live, edits: edits, copiesLocalizations: AppleConstants.newVersionCopiesLocalizations)
    }

    /// `copiesLocalizations` false (no live trial has shown yet that Apple copies the Live texts into a new version): each
    /// Live locale without a changed text is carried over with its Live text, so the new version holds every Live text either
    /// way. When Apple did copy it, the Executor finds the text already in the version and writes nothing for it.
    mutating func addTextsInNewVersion(owner: LocalizationOwner, live: MetadataVersion, edits: [LocalizationEdit],
                                       copiesLocalizations: Bool) {
        var liveRows: [String: LocalizationRow] = [:]
        for row in snapshot.metadata[owner]?.localizations ?? [] where row.versionId == live.ascId { liveRows[row.locale] = row }
        var texts: [String: LocalizationText] = [:]
        for edit in edits {
            if let text = Self.newVersionText(edit, current: liveRows[edit.locale]?.text, kind: owner.kind) { texts[edit.locale] = text }
        }
        guard !texts.isEmpty else { return }
        if !copiesLocalizations {
            for (locale, row) in liveRows where texts[locale] == nil { texts[locale] = row.text }
        }
        let version = MetadataVersion(ascId: PlannedRow.ascId, owner: owner, number: live.number + 1, state: .prepareForSubmission)
        let versionSeq = sink.add(.metadataVersion(owner: owner), .createMetadataVersion(owner: owner),
                                  before: .metadataVersion(nil), target: .metadataVersion(version), rules: ["N5"])
        for locale in texts.keys.sorted() {
            guard let text = texts[locale] else { continue }
            let cell = CellKey.localization(owner: owner, locale: locale)
            let row = LocalizationRow(ascId: PlannedRow.ascId, owner: owner, versionId: PlannedRow.ascId, locale: locale, text: text)
            sink.add(cell, .setLocalization(SetLocalization(owner: owner, locale: locale, text: text, localizationId: nil, versionId: nil)),
                     before: snapshot.cellState(cell, on: today),
                     target: .localization(live: liveRows[locale], pending: row, pendingVersion: version),
                     dependsOn: [versionSeq], rules: ["N1", "N2", "N3", "N4"])
        }
    }

    /// The text a locale gets in the new version: `desiredText` (an empty field keeps the Live text, L-D3) over the Live
    /// text `current`. nil when nothing changes or a new locale has no text at all. A new locale without a name gets an empty
    /// name, which rules N3 and N4 block. `kind` is the owner kind of `edit`; `desiredText` reads it from the edit itself.
    static func newVersionText(_ edit: LocalizationEdit, current: LocalizationText?, kind: LocalizationOwnerKind) -> LocalizationText? {
        if current == nil, !hasText(edit) { return nil }
        let desired = desiredText(for: edit, current: current)
        return desired == current ? nil : desired
    }
}
