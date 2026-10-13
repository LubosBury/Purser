import Foundation
import Domain

extension Verdict {
    static func block(_ rule: RuleID, _ scope: BlockScope, _ cell: CellKey?, _ message: String) -> Verdict {
        Verdict(rule: rule, severity: .block(scope), cell: cell, message: message)
    }

    static func warn(_ rule: RuleID, _ cell: CellKey?, _ message: String) -> Verdict {
        Verdict(rule: rule, severity: .warn, cell: cell, message: message)
    }

    static func c2(_ rule: RuleID, _ cell: CellKey?, _ message: String, riskClass: String) -> Verdict {
        Verdict(rule: rule, severity: .confirm(.c2), cell: cell, message: message, riskClass: riskClass)
    }
}

enum Format {
    /// 0.2 -> "20.0 %".
    static func percent(_ fraction: Decimal) -> String {
        var value = fraction * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 1, .plain)
        let text = "\(rounded)"
        return (text.contains(".") ? text : text + ".0") + " %"
    }

    static func ratio(_ value: Decimal) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 2, .plain)
        return "\(rounded)"
    }

    static func list(_ items: [String], limit: Int = 10) -> String {
        let head = items.prefix(limit).joined(separator: ", ")
        return items.count > limit ? "\(head) … and \(items.count - limit) more" : head
    }
}

extension PlannedItem {
    var newRegular: NewRegularPrice? { if case let .createRegularPrice(p) = payload { return p } else { return nil } }
    var newIntro: NewIntroOffer? { if case let .createIntro(o) = payload { return o } else { return nil } }
    var newPromo: NewPromoOffer? { if case let .createPromo(o) = payload { return o } else { return nil } }
    var newIAPSchedule: NewIAPSchedule? { if case let .replaceIAPSchedule(s) = payload { return s } else { return nil } }

    /// The row the item creates, read from its target state.
    var createdRegularRow: RegularPriceRow? {
        guard let p = newRegular, case let .regular(current, scheduled) = target else { return nil }
        return [scheduled, current].compactMap { $0 }.first { $0.pricePointId == p.pricePointId && $0.startDate == p.startDate }
    }

    var beforeRegular: (current: RegularPriceRow?, scheduled: RegularPriceRow?)? {
        if case let .regular(c, s) = before { return (c, s) } else { return nil }
    }

    var beforeIntro: (current: IntroOfferRow?, future: IntroOfferRow?)? {
        if case let .intro(c, f) = before { return (c, f) } else { return nil }
    }
}
