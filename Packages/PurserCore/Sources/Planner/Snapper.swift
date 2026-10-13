import Foundation
import Domain
import Catalog

enum SnapDirection: Sendable {
    /// Regular prices: the nearest point (a tie goes to the cheaper point).
    case nearest
    /// Intro, promo and discounts: the highest point that is not above the amount.
    case down
}

struct SnapResult: Hashable, Sendable {
    var point: PricePoint
    var deviation: Decimal
    var warning: Verdict?
}

enum SnapOutcome: Hashable, Sendable {
    case snapped(SnapResult)
    case blocked(Verdict)
}

/// Rule S4: snapping to price points of the same product, territory and plan type.
struct Snapper: Sendable {
    let index: PricePointIndex

    static func deviation(of price: Decimal, from amount: Decimal) -> Decimal {
        let diff = price - amount
        return (diff < 0 ? -diff : diff) / amount
    }

    func snap(_ amount: Decimal, productAscId: String, territory: TerritoryCode, planType: PlanType?,
              direction: SnapDirection, cell: CellKey) -> SnapOutcome {
        guard amount > 0 else {
            return .blocked(Verdict(rule: "S4", severity: .block(.cell), cell: cell, message: "The target amount \(amount) is not positive."))
        }
        var points = index.points(productAscId: productAscId, territory: territory, planType: planType)
        if points.isEmpty, planType != nil { points = index.points(productAscId: productAscId, territory: territory, planType: nil) }
        let chosen: PricePoint?
        switch direction {
        case .nearest:
            chosen = points.min { Self.deviation(of: $0.customerPrice, from: amount) < Self.deviation(of: $1.customerPrice, from: amount) }
        case .down:
            chosen = points.last { $0.customerPrice <= amount }
        }
        guard let point = chosen else {
            let what = direction == .down ? "≤ \(amount)" : "for \(amount)"
            return .blocked(Verdict(rule: "S4", severity: .block(.cell), cell: cell, message: "There is no price point \(what) in \(territory)."))
        }
        let deviation = Self.deviation(of: point.customerPrice, from: amount)
        if deviation > AppleConstants.snapBlockDeviation {
            return .blocked(Verdict(rule: "S4", severity: .block(.cell), cell: cell,
                                    message: "The deviation \(percent(deviation)) (target \(amount) → point \(point.customerPrice)) is more than \(percent(AppleConstants.snapBlockDeviation))."))
        }
        let warning = deviation > AppleConstants.snapWarnDeviation
            ? Verdict(rule: "S4", severity: .warn, cell: cell,
                      message: "The deviation \(percent(deviation)) (target \(amount) → point \(point.customerPrice)) is more than \(percent(AppleConstants.snapWarnDeviation)).")
            : nil
        return .snapped(SnapResult(point: point, deviation: deviation, warning: warning))
    }

    private func percent(_ fraction: Decimal) -> String {
        var value = fraction * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 1, .plain)
        return "\(rounded) %"
    }
}
