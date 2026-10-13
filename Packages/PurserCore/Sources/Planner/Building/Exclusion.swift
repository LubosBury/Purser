import Foundation
import Domain

enum Exclusion {
    /// Removes every item of `cells`, every item that depends on a removed item, and the rest of any cell that lost an item;
    /// renumbers the remaining items 1...n and re-links dependsOn.
    static func apply(_ cells: Set<CellKey>, to items: [PlannedItem]) -> (items: [PlannedItem], excluded: Set<CellKey>) {
        var removedCells = cells
        var removed = Set(items.filter { removedCells.contains($0.cell) }.map(\.seq))
        var changed = true
        while changed {
            changed = false
            for item in items where !removed.contains(item.seq)
                && (removedCells.contains(item.cell) || item.dependsOn.contains(where: removed.contains)) {
                removed.insert(item.seq)
                removedCells.insert(item.cell)
                changed = true
            }
        }
        let kept = items.filter { !removed.contains($0.seq) }.sorted { $0.seq < $1.seq }
        var newSeq: [Int: Int] = [:]
        for (index, item) in kept.enumerated() { newSeq[item.seq] = index + 1 }
        let renumbered = kept.map { item in
            PlannedItem(seq: newSeq[item.seq]!, cell: item.cell, payload: item.payload, before: item.before, target: item.target,
                        dependsOn: item.dependsOn.compactMap { newSeq[$0] }, rules: item.rules, flags: item.flags)
        }
        let touched = Set(items.map(\.cell))
        return (renumbered, removedCells.intersection(touched).union(cells))
    }
}
