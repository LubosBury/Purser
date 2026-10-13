import Foundation
import Domain

/// ascId of rows that a plan creates; the real id is known only after the write.
/// K9 convention: "" in before/target (PromoPrice.ascId, IAPManualPrice.ascId and IAPSchedule.scheduleId use nil);
/// the M2 Reconciler treats it as a wildcard.
enum PlannedRow {
    static let ascId = ""
}

/// Collects items in emission order; seq = position (1-based).
struct ItemSink {
    private(set) var items: [PlannedItem] = []

    @discardableResult
    mutating func add(_ cell: CellKey, _ payload: WritePayload, before: CellState, target: CellState,
                      dependsOn: [Int] = [], rules: [RuleID] = [], flags: [ItemFlag] = []) -> Int {
        let seq = items.count + 1
        items.append(PlannedItem(seq: seq, cell: cell, payload: payload, before: before, target: target,
                                 dependsOn: Array(Set(dependsOn)).sorted(), rules: Array(Set(rules)).sorted(), flags: flags))
        return seq
    }
}
