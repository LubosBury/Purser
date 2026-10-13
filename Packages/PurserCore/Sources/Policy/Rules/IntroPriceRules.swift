import Foundation
import Domain
import Catalog

enum IntroPriceMath {
    /// Regular price an intro price is compared with: the per-period price times the periods a PAY_UP_FRONT price covers.
    static func multiplier(_ row: IntroOfferRow, _ snapshot: CatalogSnapshot) -> Decimal {
        guard let period = snapshot.subscriptions[row.subscriptionId]?.period else { return 1 }
        return OfferMath.regularMultiplier(mode: row.mode, duration: row.duration, period: period)
    }

    /// I4: first day of the remaining validity on which the intro is not cheaper than the regular price.
    static func i4Violation(_ row: IntroOfferRow, _ projection: PlanProjection) -> (day: CalendarDate, regular: Decimal, from: CalendarDate)? {
        guard row.mode != .freeTrial, let price = row.customerPrice, let window = IntroWindow(row: row, today: projection.today) else { return nil }
        let multiplier = multiplier(row, projection.snapshot)
        for (day, regular) in projection.regularPrices(row.subscriptionId, row.territory, row.planType, from: window.from, to: window.to)
        where price >= regular * multiplier {
            return (day, regular * multiplier, window.from)
        }
        return nil
    }

    /// I5: effective discount against the lowest regular price in the I4 window.
    static func discount(_ row: IntroOfferRow, _ projection: PlanProjection) -> Decimal? {
        guard row.mode != .freeTrial, let price = row.customerPrice, let window = IntroWindow(row: row, today: projection.today),
              let lowest = projection.regularPrices(row.subscriptionId, row.territory, row.planType, from: window.from, to: window.to)
                .map(\.price).min(), lowest > 0 else { return nil }
        return 1 - price / (lowest * multiplier(row, projection.snapshot))
    }

    static func currency(_ snapshot: CatalogSnapshot, _ territory: TerritoryCode) -> String {
        snapshot.territories[territory].map { " \($0)" } ?? ""
    }
}

/// I4*: an intro is cheaper than the regular price on every day of its remaining validity (post-plan state when planning).
struct I4IntroBelowRegularRule: PlanRule, InvariantRule {
    let id: RuleID = "I4"

    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let projection = PlanProjection(snapshot: context.snapshot, items: context.items, today: context.today)
        let introCellsInPlan = Set(context.items.map(\.cell).filter { if case .intro = $0 { return true } else { return false } })
        var verdicts: [Verdict] = []
        for cell in projection.touchedPriceCells.sorted() {
            for row in projection.introRows(cell.subscriptionId, cell.territory, cell.planType) {
                guard let v = IntroPriceMath.i4Violation(row, projection) else { continue }
                let target = introCellsInPlan.contains(cell.introCell) ? cell.introCell : cell.regularCell
                verdicts.append(.block(id, .cell, target, message(row, v, context.snapshot)))
            }
        }
        return verdicts
    }

    func check(_ snapshot: CatalogSnapshot, today: CalendarDate) -> [Verdict] {
        let projection = PlanProjection(snapshot: snapshot, items: [], today: today)
        let cells = Set(snapshot.introRows.map { PriceCell(subscriptionId: $0.subscriptionId, territory: $0.territory, planType: $0.planType) })
        var verdicts: [Verdict] = []
        for cell in cells.sorted() {
            for row in projection.introRows(cell.subscriptionId, cell.territory, cell.planType) {
                guard let v = IntroPriceMath.i4Violation(row, projection) else { continue }
                verdicts.append(.block(id, .cell, cell.introCell, message(row, v, snapshot)))
            }
        }
        return verdicts
    }

    private func message(_ row: IntroOfferRow, _ v: (day: CalendarDate, regular: Decimal, from: CalendarDate), _ snapshot: CatalogSnapshot) -> String {
        let currency = IntroPriceMath.currency(snapshot, row.territory)
        let since = v.day > v.from ? " effective from \(v.day)" : ""
        return "The intro \(row.customerPrice ?? 0)\(currency) is not cheaper than the regular price \(v.regular)\(currency)\(since)."
    }
}

/// I5 (plan): the effective discount of a new paid intro is at least the nominal discount; more than 5 pp deeper warns.
struct I5NominalDiscountRule: PlanRule {
    let id: RuleID = "I5"

    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let projection = PlanProjection(snapshot: context.snapshot, items: context.items, today: context.today)
        var verdicts: [Verdict] = []
        for item in context.items {
            guard let offer = item.newIntro, let nominal = context.spec.nominalDiscounts[offer.subscriptionId],
                  case let .intro(current, future) = item.target,
                  let row = [future, current].compactMap({ $0 }).first(where: { $0.pricePointId == offer.pricePointId && $0.startDate == offer.startDate }),
                  let discount = IntroPriceMath.discount(row, projection) else { continue }
            if let verdict = I5Check.verdict(id, item.cell, discount: discount, nominal: nominal) { verdicts.append(verdict) }
        }
        return verdicts
    }
}

/// I5*: live intros of products with a configured nominal discount.
struct I5NominalDiscountInvariant: InvariantRule {
    let id: RuleID = "I5"
    let nominalDiscounts: [String: Decimal]

    func check(_ snapshot: CatalogSnapshot, today: CalendarDate) -> [Verdict] {
        guard !nominalDiscounts.isEmpty else { return [] }
        let projection = PlanProjection(snapshot: snapshot, items: [], today: today)
        let cells = Set(snapshot.introRows.map { PriceCell(subscriptionId: $0.subscriptionId, territory: $0.territory, planType: $0.planType) })
        var verdicts: [Verdict] = []
        for cell in cells.sorted() {
            guard let nominal = nominalDiscounts[cell.subscriptionId] else { continue }
            for row in projection.introRows(cell.subscriptionId, cell.territory, cell.planType) {
                guard let discount = IntroPriceMath.discount(row, projection) else { continue }
                if let verdict = I5Check.verdict(id, cell.introCell, discount: discount, nominal: nominal) { verdicts.append(verdict) }
            }
        }
        return verdicts
    }
}

enum I5Check {
    static func verdict(_ id: RuleID, _ cell: CellKey, discount: Decimal, nominal: Decimal) -> Verdict? {
        if discount < nominal {
            return .block(id, .cell, cell, "The discount \(Format.percent(discount)) is smaller than the nominal \(Format.percent(nominal)).")
        }
        if discount - nominal > AppleConstants.i5ExtraDepthWarn {
            return .warn(id, cell, "The discount \(Format.percent(discount)) is more than \(Format.percent(AppleConstants.i5ExtraDepthWarn)) deeper than the nominal \(Format.percent(nominal)).")
        }
        return nil
    }
}
