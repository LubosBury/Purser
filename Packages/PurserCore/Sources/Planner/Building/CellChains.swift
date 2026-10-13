import Foundation
import Domain
import Catalog

extension PlanBuilder {
    /// Regular cell: [DELETE of the scheduled change (R5)] -> POST. Returns the seq of the last item.
    @discardableResult
    mutating func emitRegularChain(_ intent: RegularIntent?, after dependencies: [Int]) -> Int? {
        guard let intent else { return nil }
        let cell = intent.key.regularCell
        guard case let .regular(current, scheduled) = snapshot.cellState(cell, on: today) else { return nil }
        var deps = dependencies
        var rules: [RuleID] = ["R1"]
        if let scheduled {
            rules.append("R5")
            deps = [sink.add(cell, .deleteRegularPrice(ascId: scheduled.ascId), before: .regular(current: current, scheduled: scheduled),
                             target: .regular(current: current, scheduled: nil), dependsOn: deps, rules: rules)]
        }
        let k = intent.key
        let row = RegularPriceRow(ascId: PlannedRow.ascId, subscriptionId: k.subscriptionId, territory: k.territory, planType: k.planType,
                                  rawPlanType: k.planType.rawValue, startDate: intent.startDate, preserved: false,
                                  pricePointId: intent.point.id, customerPrice: intent.point.customerPrice)
        let startsLater = intent.startDate.map { $0 > today } ?? false
        let target: CellState = startsLater ? .regular(current: current, scheduled: row) : .regular(current: row, scheduled: nil)
        let payload = WritePayload.createRegularPrice(NewRegularPrice(subscriptionId: k.subscriptionId, territory: k.territory,
                                                                      planType: k.planType, pricePointId: intent.point.id,
                                                                      startDate: intent.startDate, preserveCurrentPrice: intent.preserve))
        return sink.add(cell, payload, before: .regular(current: current, scheduled: nil), target: target, dependsOn: deps, rules: rules)
    }

    /// Intro cell: [DELETE future] -> [PATCH_END live intro at D on an approved product | DELETE current otherwise] -> POST.
    @discardableResult
    mutating func emitIntroChain(_ intent: IntroIntent?, after dependencies: [Int]) -> Int? {
        guard let intent else { return nil }
        let cell = intent.key.introCell
        guard case let .intro(current, future) = snapshot.cellState(cell, on: today) else { return nil }
        if isNoOp(intent, current: current, future: future) { return nil }
        let approved = subscription(intent.key.subscriptionId)?.state == .approved
        var state: (current: IntroOfferRow?, future: IntroOfferRow?) = (current, future)
        var deps = dependencies
        if let f = future {
            deps = [sink.add(cell, .deleteIntro(ascId: f.ascId), before: .intro(current: state.current, future: f),
                             target: .intro(current: state.current, future: nil), dependsOn: deps, rules: intent.rules + ["I6"])]
            state.future = nil
        }
        if let c = current {
            let start = intent.startDate ?? today
            if approved {
                if c.endDate.map({ $0 > start }) ?? true {
                    var ended = c
                    ended.endDate = start
                    deps = [sink.add(cell, .endIntro(ascId: c.ascId, endDate: start), before: .intro(current: c, future: state.future),
                                     target: .intro(current: ended, future: state.future), dependsOn: deps, rules: intent.rules + ["I7"])]
                    state.current = ended
                }
            } else {
                deps = [sink.add(cell, .deleteIntro(ascId: c.ascId), before: .intro(current: c, future: state.future),
                                 target: .intro(current: nil, future: state.future), dependsOn: deps, rules: intent.rules + ["I6"])]
                state.current = nil
            }
        }
        let k = intent.key
        let offer = NewIntroOffer(subscriptionId: k.subscriptionId, territory: k.territory, planType: k.planType, mode: intent.mode,
                                  duration: intent.duration, numberOfPeriods: intent.periods, startDate: intent.startDate,
                                  endDate: intent.endDate, pricePointId: intent.point?.id)
        let row = IntroOfferRow(ascId: PlannedRow.ascId, subscriptionId: k.subscriptionId, territory: k.territory, planType: k.planType,
                                rawPlanType: k.planType.rawValue, mode: intent.mode, duration: intent.duration,
                                numberOfPeriods: intent.periods, startDate: intent.startDate, endDate: intent.endDate,
                                pricePointId: intent.point?.id, customerPrice: intent.point?.customerPrice)
        let startsLater = intent.startDate.map { $0 > today } ?? false
        let target: CellState = startsLater ? .intro(current: state.current, future: row) : .intro(current: row, future: state.future)
        return sink.add(cell, .createIntro(offer), before: .intro(current: state.current, future: state.future), target: target,
                        dependsOn: deps, rules: intent.rules + ["I3"], flags: intent.flags)
    }

    /// The cell already holds exactly this offer.
    private func isNoOp(_ intent: IntroIntent, current: IntroOfferRow?, future: IntroOfferRow?) -> Bool {
        func same(_ row: IntroOfferRow) -> Bool {
            row.mode == intent.mode && row.duration == intent.duration && row.numberOfPeriods == intent.periods
                && row.pricePointId == intent.point?.id && row.endDate == intent.endDate
        }
        if let current, future == nil, same(current) { return true }
        if current == nil, let future, same(future), future.startDate == intent.startDate { return true }
        return false
    }
}
