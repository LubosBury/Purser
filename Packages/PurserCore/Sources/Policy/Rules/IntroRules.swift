import Foundation
import Domain
import Catalog

/// I2: mode, duration and number of periods fit the subscription period (intro and promo offers).
struct I2OfferShapeRule: PlanRule {
    let id: RuleID = "I2"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            let shape: (OfferMode, OfferDuration, Int)
            if let o = item.newIntro { shape = (o.mode, o.duration, o.numberOfPeriods) }
            else if let o = item.newPromo { shape = (o.mode, o.duration, o.numberOfPeriods) }
            else { return nil }
            guard let period = context.snapshot.subscriptions[item.cell.productAscId]?.period,
                  !OfferMath.isValidShape(mode: shape.0, duration: shape.1, periods: shape.2, period: period) else { return nil }
            return .block(id, .cell, item.cell, "\(shape.0.rawValue) \(shape.1.rawValue) × \(shape.2) does not match the subscription period \(period.rawValue).")
        }
    }
}

/// I6: at most one current and one future intro; a new intro must not overlap a row that the plan did not end or delete first.
struct I6IntroSlotsRule: PlanRule {
    let id: RuleID = "I6"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let offer = item.newIntro, let before = item.beforeIntro else { return nil }
            let start = offer.startDate ?? context.today
            for row in [before.current, before.future].compactMap({ $0 }) {
                if let end = row.endDate, end <= context.today { continue }
                let rowStartsBeforeNewEnds = offer.endDate.map { (row.startDate ?? context.today) < $0 } ?? true
                let newStartsBeforeRowEnds = row.endDate.map { start < $0 } ?? true
                if rowStartsBeforeNewEnds && newStartsBeforeRowEnds {
                    return .block(id, .cell, item.cell, "The new intro from \(start) overlaps the intro \(row.ascId); the plan must end or delete it first.")
                }
            }
            return nil
        }
    }
}

/// I7: a live intro on an approved subscription is never deleted; it is ended at D >= today + minLeadDays and replaced from D.
/// Until spike S4b confirms the behaviour only a CANARY plan (one territory per product, C2) may do that; an Effective
/// canary of a product (spec.effectiveLiveIntroCanaryProducts, CR-11) unlocks the rest of that product.
struct I7LiveIntroRule: PlanRule {
    let id: RuleID = "I7"
    var liveReplaceConfirmed: Bool = AppleConstants.introLiveReplaceConfirmed

    func evaluate(_ context: PolicyContext) -> [Verdict] {
        var verdicts: [Verdict] = []
        var replacedCells: [CellKey] = []
        let unlocked = context.spec.effectiveLiveIntroCanaryProducts
        let earliest = context.today.adding(days: AppleConstants.minLeadDays)
        for item in context.items {
            guard case .intro = item.cell, context.snapshot.subscriptions[item.cell.productAscId]?.state == .approved,
                  let live = item.beforeIntro?.current, live.isActive(on: context.today) else { continue }
            switch item.payload {
            case let .deleteIntro(ascId) where ascId == live.ascId:
                verdicts.append(.block(id, .plan, item.cell, "The live intro \(ascId) must not be deleted; it is replaced by PATCH_END + POST."))
            case let .endIntro(ascId, end) where ascId == live.ascId:
                if end < earliest {
                    verdicts.append(.block(id, .plan, item.cell, "A live intro can end on \(earliest) at the earliest; the plan wants \(end)."))
                }
                replacedCells.append(item.cell)
            default:
                continue
            }
        }
        let lockedCells = replacedCells.filter { !unlocked.contains($0.productAscId) }
        if !lockedCells.isEmpty && !liveReplaceConfirmed {
            if context.spec.canary {
                for cell in lockedCells {
                    verdicts.append(.c2(id, cell, "Canary: replacing a live intro before spike S4b confirms it.", riskClass: "I7 canary of a live intro replacement"))
                }
            } else {
                verdicts.append(.block(id, .plan, nil, "Replacing a live intro (\(lockedCells.count) cells) waits for spike S4b; for now only a CANARY plan or a product with an Effective canary may run."))
            }
        }
        if context.spec.canary {
            var territories: [String: Set<TerritoryCode>] = [:]
            for item in context.items where !unlocked.contains(item.cell.productAscId) {
                if let t = item.cell.territory { territories[item.cell.productAscId, default: []].insert(t) }
            }
            for (product, set) in territories.sorted(by: { $0.key < $1.key }) where set.count > 1 {
                verdicts.append(.block(id, .plan, nil, "A CANARY may have 1 territory per product; \(product) has \(set.count)."))
            }
        }
        return verdicts
    }
}

/// I8: a regular price change on day D in a cell with a paid intro needs a replacement intro starting on the same day
/// (max(D, start of the intro) for an intro that starts later), or an explicit skip with a reason (C2).
/// On resume a replacement the plan already wrote counts too (`writtenItems`).
struct I8IntroReplacementRule: PlanRule {
    let id: RuleID = "I8"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let price = item.newRegular else { return nil }
            let day = price.startDate ?? context.today
            let introCell: CellKey = .intro(subscriptionId: price.subscriptionId, territory: price.territory, planType: price.planType)
            guard case let .intro(current, future) = context.snapshot.cellState(introCell, on: context.today) else { return nil }
            let paid = [current, future].compactMap { $0 }.filter { $0.pricePointId != nil && ($0.endDate.map { $0 > day } ?? true) }
            guard !paid.isEmpty else { return nil }
            let starts = Set((context.items + context.writtenItems).filter { $0.cell == introCell }
                .compactMap { $0.newIntro.map { $0.startDate ?? context.today } })
            let replaced = paid.allSatisfy { starts.contains(max(day, $0.startDate ?? context.today)) }
            if replaced { return nil }
            if let reason = context.spec.skippedIntroReplacements[introCell] {
                return .c2(id, introCell, "Replacement of the paid intro left out: \(reason)", riskClass: "I8 intro replacement left out")
            }
            return .block(id, .cell, item.cell, "The cell has a paid intro; the plan must contain its replacement from \(day), or leave it out with a reason.")
        }
    }
}

/// I9: one intro per customer and subscription group; Korea asks for consent when the intro converts.
struct I9IntroEligibilityRule: PlanRule {
    let id: RuleID = "I9"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let intros = context.items.filter { $0.newIntro != nil }
        guard !intros.isEmpty else { return [] }
        var verdicts: [Verdict] = [.warn(id, nil, "Only a customer who has not yet had an intro in the subscription group gets the intro.")]
        for item in intros where item.cell.territory == "KOR" {
            verdicts.append(.warn(id, item.cell, "Korea: Apple requires the customer's consent when moving from an intro to the full price."))
        }
        return verdicts
    }
}
