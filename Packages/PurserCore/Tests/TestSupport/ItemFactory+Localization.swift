import Foundation
import Domain
import Catalog

extension ItemFactory {
    /// A SET_TEXT item the way the L10N builder makes it: PATCH when the version in preparation has the locale, else POST into it.
    public static func text(_ seq: Int, _ snapshot: CatalogSnapshot, owner: LocalizationOwner, locale: String, text: LocalizationText) -> PlannedItem {
        let cell = CellKey.localization(owner: owner, locale: locale)
        let before = snapshot.cellState(cell, on: SyntheticCatalog.today)
        let version = snapshot.pendingVersion(of: owner)
        let current = version.flatMap { snapshot.localization(owner, locale: locale, versionId: $0.ascId) }
        var live: LocalizationRow?
        if case let .localization(row, _, _) = before { live = row }
        let row = version.map { LocalizationRow(ascId: current?.ascId ?? planned, owner: owner, versionId: $0.ascId, locale: locale, text: text) }
        return PlannedItem(seq: seq, cell: cell,
                           payload: .setLocalization(SetLocalization(owner: owner, locale: locale, text: text, localizationId: current?.ascId,
                                                                     versionId: current == nil ? version?.ascId : nil)),
                           before: before, target: .localization(live: live, pending: row, pendingVersion: version),
                           rules: ["N1", "N2", "N3", "N4"])
    }
}
