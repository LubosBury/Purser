import Foundation
import Domain
import Catalog

/// R3*: with MONTHLY available, 1.0 <= 12 x monthly / upfront <= 1.5 on every day (today and each scheduled change).
struct R3MonthlyRatioRule: PlanRule, InvariantRule {
    let id: RuleID = "R3"

    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let projection = PlanProjection(snapshot: context.snapshot, items: context.items, today: context.today)
        let cells = Set(context.items.compactMap { item -> PriceCell? in
            guard case let .regular(s, t, .upfront) = item.cell, context.snapshot.subscriptions[s]?.monthlyPlanAvailable == true else { return nil }
            return PriceCell(subscriptionId: s, territory: t, planType: .upfront)
        })
        return cells.sorted().compactMap { violation($0, projection: projection, today: context.today) }
    }

    func check(_ snapshot: CatalogSnapshot, today: CalendarDate) -> [Verdict] {
        let projection = PlanProjection(snapshot: snapshot, items: [], today: today)
        var verdicts: [Verdict] = []
        for subscription in snapshot.subscriptions.values.sorted(by: { $0.ascId < $1.ascId }) where subscription.monthlyPlanAvailable {
            for territory in subscription.availableTerritories.sorted() {
                let cell = PriceCell(subscriptionId: subscription.ascId, territory: territory, planType: .upfront)
                if let verdict = violation(cell, projection: projection, today: today) { verdicts.append(verdict) }
            }
        }
        return verdicts
    }

    private func violation(_ cell: PriceCell, projection: PlanProjection, today: CalendarDate) -> Verdict? {
        let s = cell.subscriptionId, t = cell.territory
        var days = [today]
        for planType in [PlanType.upfront, .monthly] {
            if let start = projection.regular(s, t, planType).scheduled?.startDate, start > today { days.append(start) }
        }
        for day in days.sorted() {
            guard let upfront = projection.regularPrice(s, t, .upfront, on: day), upfront > 0,
                  let monthly = projection.regularPrice(s, t, .monthly, on: day) else { continue }
            let ratio = 12 * monthly / upfront
            if ratio < AppleConstants.monthlyRatioMin || ratio > AppleConstants.monthlyRatioMax {
                let since = day > today ? " from \(day)" : ""
                return .block(id, .cell, cell.regularCell,
                              "12 × monthly / yearly = \(Format.ratio(ratio))\(since); allowed is \(AppleConstants.monthlyRatioMin)–\(AppleConstants.monthlyRatioMax).")
            }
        }
        return nil
    }
}
