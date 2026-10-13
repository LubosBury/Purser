import Foundation
import Domain
import Catalog

extension PlanBuilder {
    /// DELETE of Done items of another plan whose row is still in the future (regular price change, future intro).
    mutating func addWithdraw(_ spec: WithdrawPlanSpec) throws {
        guard let stored = context.referencedItems[spec.planId] else { throw PlanningError.missingReferencedPlan(spec.planId) }
        var withdrawn = 0
        for seq in spec.itemSeqs.sorted() {
            guard let item = stored.first(where: { $0.item.seq == seq }) else {
                warn("Item \(seq) is not in plan \(spec.planId).")
                continue
            }
            guard item.state == .done, let ascId = item.ascId else {
                warn("Item \(seq) is not Done (\(item.state.rawValue)); only a written item can be rolled back.")
                continue
            }
            let cell = item.item.cell
            switch item.item.payload {
            case let .createRegularPrice(price):
                guard let start = price.startDate, start > today,
                      case let .regular(current, scheduled?) = snapshot.cellState(cell, on: today), scheduled.ascId == ascId else {
                    warn("The regular price from item \(seq) is no longer scheduled; it can be reverted only by a new change.")
                    continue
                }
                sink.add(cell, .deleteRegularPrice(ascId: ascId), before: .regular(current: current, scheduled: scheduled),
                         target: .regular(current: current, scheduled: nil), rules: ["R6"])
                withdrawn += 1
            case let .createIntro(offer):
                guard let start = offer.startDate, start > today,
                      case let .intro(current, future?) = snapshot.cellState(cell, on: today), future.ascId == ascId else {
                    warn("The intro from item \(seq) is already running or is not in ASC; it can be ended by a new intro plan.")
                    continue
                }
                sink.add(cell, .deleteIntro(ascId: ascId), before: .intro(current: current, future: future),
                         target: .intro(current: current, future: nil), rules: ["I6"])
                withdrawn += 1
            default:
                warn("Item \(seq) (\(item.item.op.rawValue)) cannot be rolled back.")
            }
        }
        if withdrawn == 0 {
            verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: nil, message: "There is nothing to roll back in plan \(spec.planId)."))
        }
    }

    private mutating func warn(_ message: String) {
        verdicts.append(Verdict(rule: PlannerRule.plan, severity: .warn, cell: nil, message: message))
    }
}
