import Foundation
import Domain
import Catalog

/// A2: apply on a production workspace needs C1.
struct A2ProductionRule: PlanRule {
    let id: RuleID = "A2"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        guard context.config.isProduction else { return [] }
        return [Verdict(rule: id, severity: .confirm(.c1), cell: nil, message: "Production workspace: confirm by typing the app name.")]
    }
}

/// A3: only one plan may be Applying on a workspace.
struct A3SingleApplyingRule: PlanRule {
    let id: RuleID = "A3"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        guard !context.otherApplyingPlanIds.isEmpty else { return [] }
        return [.block(id, .plan, nil, "An apply of plan \(context.otherApplyingPlanIds.sorted().joined(separator: ", ")).")]
    }
}

/// A4 (draft-time part): the first item of every cell must start from the cell state in the current snapshot.
/// A text item is compared with LocalizationSemantics.matches, as the Reconciler compares it: the same effective text, and
/// a text planned into a version in preparation needs that same version (by id), still editable. So its version going from
/// PREPARE_FOR_SUBMISSION to READY_FOR_REVIEW (both editable) does not block, while a version that went into review, or
/// was approved and followed by a new one (even one holding a copy of its texts), does. A text planned without a version
/// in preparation does not block on a version the plan created, which holds the texts Apple copied into it while the Live
/// text stays. Every other item is compared exactly.
struct A4FreshBaseRule: PlanRule {
    let id: RuleID = "A4"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        var first: [CellKey: PlannedItem] = [:]
        for item in context.items where (first[item.cell]?.seq ?? Int.max) > item.seq { first[item.cell] = item }
        let stale = first.values.filter { !Self.startsFromSnapshot($0, context.snapshot.cellState($0.cell, on: context.today)) }
            .map(\.cell.storageKey).sorted()
        guard !stale.isEmpty else { return [] }
        return [.block(id, .plan, nil, "The plan does not match the current snapshot (\(Format.list(stale, limit: 5))); do a Re-plan.")]
    }

    static func startsFromSnapshot(_ item: PlannedItem, _ live: CellState) -> Bool {
        if item.before == live { return true }
        guard case .setLocalization = item.payload else { return false }
        return LocalizationSemantics.matches(live: live, expected: item.before)
    }
}

/// A5: Purser writes only to products in a writable state. A subscription group has no product state: its texts need only
/// the group in the catalog.
struct A5ProductStateRule: PlanRule {
    let id: RuleID = "A5"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let owners = context.items.compactMap(\.cell.localizationOwner)
        let groups = Set(owners.filter { $0.kind == .group }.map(\.ascId))
        let missingGroups = groups.sorted().filter { context.snapshot.groups[$0] == nil }.map {
            Verdict.block(id, .plan, nil, "The subscription group \($0) is not in the catalog.")
        }
        let products = Set(context.items.map(\.cell.productAscId)).subtracting(groups)
        return missingGroups + products.sorted().compactMap { ascId -> Verdict? in
            let state = context.snapshot.subscriptions[ascId]?.state ?? context.snapshot.iaps[ascId]?.state
            guard let state else { return .block(id, .plan, nil, "The product \(ascId) is not in the catalog.") }
            guard !ProductState.writable.contains(state) else { return nil }
            return .block(id, .plan, nil, "The product \(ascId) is in state \(state); Purser writes only in APPROVED, READY_TO_SUBMIT, MISSING_METADATA, DEVELOPER_ACTION_NEEDED.")
        }
    }
}

/// A6: no writes for territories where the subscription is not available.
struct A6AvailabilityRule: PlanRule {
    let id: RuleID = "A6"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        var verdicts: [Verdict] = []
        for item in context.items {
            guard let subscription = context.snapshot.subscriptions[item.cell.productAscId] else { continue }
            let territories: [TerritoryCode]
            switch item.payload {
            case let .createPromo(offer): territories = offer.prices.map(\.territory)
            case let .replacePromoPrices(_, prices): territories = prices.map(\.territory)
            default: territories = item.cell.territory.map { [$0] } ?? []
            }
            let unavailable = territories.filter { !subscription.availableTerritories.contains($0) }
            if !unavailable.isEmpty {
                verdicts.append(.block(id, .cell, item.cell, "Territory outside the product's availability: \(Format.list(unavailable.map(\.rawValue)))."))
            }
        }
        return Array(Set(verdicts))
    }
}

/// A6*: intro offers that exist in territories outside the product's availability.
struct A6AvailabilityInvariant: InvariantRule {
    let id: RuleID = "A6"
    func check(_ snapshot: CatalogSnapshot, today: CalendarDate) -> [Verdict] {
        var cells: Set<CellKey> = []
        for row in snapshot.introRows where row.endDate.map({ $0 > today }) ?? true {
            guard let subscription = snapshot.subscriptions[row.subscriptionId],
                  !subscription.availableTerritories.contains(row.territory) else { continue }
            cells.insert(.intro(subscriptionId: row.subscriptionId, territory: row.territory, planType: row.planType))
        }
        return cells.map { .block(id, .cell, $0, "An intro in a territory outside the product's availability.") }
    }
}

/// A7: the plan warns when it needs more requests than the hourly budget has left.
struct A7BudgetRule: PlanRule {
    let id: RuleID = "A7"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        guard let remaining = context.rateLimit?.remaining else { return [] }
        let requests = RequestEstimator.requests(items: context.items)
        guard requests > remaining else { return [] }
        return [.warn(id, nil, "The plan needs \(requests) requests, the hourly budget has \(remaining) left; the apply will run longer and may pause (RATE).")]
    }
}
