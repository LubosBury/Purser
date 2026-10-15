import Foundation
import Domain

/// L3: a createMetadataVersion item whose remaining dependents change no text (every changed text was excluded, only
/// carried-over Live texts are left) is removed together with them: a version is never created without a text change.
enum OrphanVersions {
    static func prune(_ result: (items: [PlannedItem], excluded: Set<CellKey>)) -> (items: [PlannedItem], excluded: Set<CellKey>) {
        let needed = Set(result.items.filter(changesText).flatMap(\.dependsOn))
        let orphans = Set(result.items.filter { item in
            if case .createMetadataVersion = item.payload { return !needed.contains(item.seq) }
            return false
        }.map(\.cell))
        guard !orphans.isEmpty else { return result }
        let pruned = Exclusion.apply(orphans, to: result.items)
        return (pruned.items, result.excluded.union(pruned.excluded))
    }

    /// A text item that writes something other than the Live text of its locale (a carried-over Live text does not).
    static func changesText(_ item: PlannedItem) -> Bool {
        guard case let .setLocalization(s) = item.payload else { return false }
        return !LocalizationSemantics.carriesLiveText(s, before: item.before)
    }
}
