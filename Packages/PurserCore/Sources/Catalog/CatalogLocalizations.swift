import Foundation
import Domain

/// One locale of the Localizations section: the live text next to the text of the pending version (spec §4).
public struct CatalogLocalizationRow: Hashable, Sendable, Identifiable {
    public enum Change: String, Hashable, Sendable {
        /// No pending version, or the same text in both versions.
        case none
        /// The pending version changes the text.
        case changed
        /// The locale exists only in the pending version.
        case added
        /// The locale is in the live version but missing from the pending one.
        case removed
    }

    public var id: String { locale }
    public var locale: String
    public var cell: CellKey
    public var live: LocalizationText?
    public var pending: LocalizationText?
    public var change: Change
}

/// What the read-only Localizations section of a subscription, an IAP or a group shows.
public struct CatalogLocalizations: Hashable, Sendable {
    public var owner: LocalizationOwner
    public var liveVersion: MetadataVersion?
    public var pendingVersion: MetadataVersion?
    /// One row per locale of the live and the pending version, sorted by locale.
    public var rows: [CatalogLocalizationRow]

    public static func of(_ owner: LocalizationOwner, snapshot: CatalogSnapshot) -> CatalogLocalizations {
        let live = snapshot.liveVersion(of: owner)
        let pending = snapshot.pendingVersion(of: owner)
        let rows = snapshot.locales(of: owner).map { locale -> CatalogLocalizationRow in
            let liveText = live.flatMap { snapshot.localization(owner, locale: locale, versionId: $0.ascId)?.text }
            let pendingText = pending.flatMap { snapshot.localization(owner, locale: locale, versionId: $0.ascId)?.text }
            return CatalogLocalizationRow(locale: locale, cell: .localization(owner: owner, locale: locale), live: liveText,
                                          pending: pendingText,
                                          change: change(live: liveText, pending: pendingText, hasPendingVersion: pending != nil))
        }
        return CatalogLocalizations(owner: owner, liveVersion: live, pendingVersion: pending, rows: rows)
    }

    static func change(live: LocalizationText?, pending: LocalizationText?, hasPendingVersion: Bool) -> CatalogLocalizationRow.Change {
        guard hasPendingVersion else { return .none }
        switch (live, pending) {
        case (nil, .some): return .added
        case (.some, nil): return .removed
        case let (l?, p?): return l == p ? .none : .changed
        case (nil, nil): return .none
        }
    }
}
