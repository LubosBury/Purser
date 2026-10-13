import Foundation
import Domain
import Catalog

/// R2: no MONTHLY writes in v1.
struct R2MonthlyWriteRule: PlanRule {
    let id: RuleID = "R2"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let monthly = context.items.filter { item in
            switch item.cell {
            case let .regular(_, _, p), let .intro(_, _, p): if p == .monthly { return true }
            default: break
            }
            if let promo = item.newPromo, promo.planType == .monthly { return true }
            return false
        }
        guard !monthly.isEmpty else { return [] }
        return [.block(id, .plan, nil, "The plan contains \(monthly.count) writes of plan type MONTHLY; these are not allowed in v1.")]
    }
}

/// R4: start dates at least today + minLeadDays on approved subscriptions; never null when a price exists.
struct R4LeadTimeRule: PlanRule {
    let id: RuleID = "R4"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let earliest = context.today.adding(days: AppleConstants.minLeadDays)
        var verdicts: [Verdict] = []
        for item in context.items {
            let approved = context.snapshot.subscriptions[item.cell.productAscId]?.state == .approved
            if let price = item.newRegular {
                if price.startDate == nil, item.beforeRegular?.current != nil {
                    verdicts.append(.block(id, .cell, item.cell, "A regular price without a startDate on a subscription that already has a price."))
                } else if approved, (price.startDate ?? context.today) < earliest {
                    verdicts.append(.block(id, .cell, item.cell, "The regular price start must be \(earliest) at the earliest (today + \(AppleConstants.minLeadDays))."))
                }
            }
            if let intro = item.newIntro, approved, (intro.startDate ?? context.today) < earliest {
                verdicts.append(.block(id, .cell, item.cell, "The start of a new intro on an approved subscription must be \(earliest) at the earliest."))
            }
        }
        return verdicts
    }
}

/// R5: replacing a scheduled change (DELETE + POST in one cell) needs C2.
struct R5ReplacementRule: PlanRule {
    let id: RuleID = "R5"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let postCells = Set(context.items.filter { $0.newRegular != nil }.map(\.cell))
        return context.items.compactMap { item -> Verdict? in
            guard case let .deleteRegularPrice(ascId) = item.payload, postCells.contains(item.cell),
                  let scheduled = item.beforeRegular?.scheduled, scheduled.ascId == ascId else { return nil }
            return .c2(id, item.cell, "Replaces the change from \(scheduled.startDate?.iso ?? "?") (\(scheduled.customerPrice)).",
                       riskClass: "R5 scheduled change replaced")
        }
    }
}

/// R6: no replacement or deletion of a scheduled change less than replaceCutoffHours before its start.
/// Drafts know only the calendar day, so the check assumes the end of today: start >= today + ceil(hours / 24) + 1.
struct R6CutoffRule: PlanRule {
    let id: RuleID = "R6"
    static var minimumDays: Int { (AppleConstants.replaceCutoffHours + 23) / 24 + 1 }

    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let earliest = context.today.adding(days: Self.minimumDays)
        return context.items.compactMap { item -> Verdict? in
            guard case let .deleteRegularPrice(ascId) = item.payload,
                  let scheduled = item.beforeRegular?.scheduled, scheduled.ascId == ascId,
                  let start = scheduled.startDate, start < earliest else { return nil }
            return .block(id, .cell, item.cell, "The change from \(start) cannot be replaced or deleted less than \(AppleConstants.replaceCutoffHours) h before its start.")
        }
    }
}

/// R7: a regular price decrease needs C2 (I4, I5 and O5 run against the new price on their own).
struct R7DecreaseRule: PlanRule {
    let id: RuleID = "R7"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let row = item.createdRegularRow, let old = item.beforeRegular?.current?.customerPrice, row.customerPrice < old else { return nil }
            return .c2(id, item.cell, "Decrease \(old) → \(row.customerPrice) from \(row.startDate?.iso ?? "at once"); a decrease cannot be undone.",
                       riskClass: "R7 regular price decrease")
        }
    }
}

/// R8: an increase with preserveCurrentPrice = false needs C2.
struct R8IncreaseWithoutPreserveRule: PlanRule {
    let id: RuleID = "R8"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let price = item.newRegular, !price.preserveCurrentPrice, let row = item.createdRegularRow,
                  let old = item.beforeRegular?.current?.customerPrice, row.customerPrice > old else { return nil }
            return .c2(id, item.cell, "Increase \(old) → \(row.customerPrice) without preserveCurrentPrice: it applies to existing subscribers too.",
                       riskClass: "R8 increase without preserveCurrentPrice")
        }
    }
}

/// R9: consent forecast for increases that reach existing subscribers (preserveCurrentPrice = false).
struct R9ConsentRule: PlanRule {
    let id: RuleID = "R9"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let price = item.newRegular, !price.preserveCurrentPrice, let row = item.createdRegularRow,
                  let old = item.beforeRegular?.current?.customerPrice, row.customerPrice > old, old > 0 else { return nil }
            var labels: [String] = []
            if AppleConstants.consentAlwaysTerritories.contains(price.territory) { labels.append("CERTAIN (\(price.territory))") }
            let increase = (row.customerPrice - old) / old
            if increase > AppleConstants.consentIncreaseThreshold { labels.append("POSSIBLE (+\(Format.percent(increase)))") }
            if hadIncreaseWithinYear(context.snapshot, price: price, start: price.startDate ?? context.today) { labels.append("CUMULATIVE (increase within 12 months)") }
            guard !labels.isEmpty else { return nil }
            return .warn(id, item.cell, "Subscriber consent: \(labels.joined(separator: ", ")).")
        }
    }

    private func hadIncreaseWithinYear(_ snapshot: CatalogSnapshot, price: NewRegularPrice, start: CalendarDate) -> Bool {
        let rows = snapshot.regularRows
            .filter { $0.subscriptionId == price.subscriptionId && $0.territory == price.territory && $0.planType == price.planType && !$0.preserved }
            .sorted { ($0.startDate ?? CalendarDate(year: 1, month: 1, day: 1)) < ($1.startDate ?? CalendarDate(year: 1, month: 1, day: 1)) }
        let yearAgo = start.adding(days: -365)
        for (previous, next) in zip(rows, rows.dropFirst()) {
            if let date = next.startDate, date >= yearAgo, date <= start, next.customerPrice > previous.customerPrice { return true }
        }
        return false
    }
}
