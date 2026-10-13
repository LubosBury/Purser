#if DEBUG
import Foundation
import Domain
import Catalog
import Policy
import Planner

/// DEBUG only (spike S8): builds item chains the Planner does not emit on never-submitted subscriptions (PATCH_END -> POST),
/// so crash drills can run on the "Purser Spike" group. The plan still goes through preflight, confirmation and the Executor.
public enum DrillPlanFactory {
    /// For each territory whose current intro is a free trial without an end date: PATCH_END to `day`, then POST a free trial
    /// of `newDuration` from `day`.
    public static func endThenPost(snapshot: CatalogSnapshot, subscriptionId: String, territories: [TerritoryCode],
                                   day: CalendarDate, newDuration: OfferDuration, today: CalendarDate) -> [PlannedItem] {
        var items: [PlannedItem] = []
        var seq = 1
        for territory in territories.sorted() {
            let cell = CellKey.intro(subscriptionId: subscriptionId, territory: territory, planType: .upfront)
            guard case let .intro(current?, nil) = snapshot.cellState(cell, on: today), current.mode == .freeTrial, current.endDate == nil else { continue }
            var ended = current
            ended.endDate = day
            let created = IntroOfferRow(ascId: "", subscriptionId: subscriptionId, territory: territory, planType: .upfront, rawPlanType: "UPFRONT",
                                        mode: .freeTrial, duration: newDuration, numberOfPeriods: 1, startDate: day, endDate: nil,
                                        pricePointId: nil, customerPrice: nil)
            let offer = NewIntroOffer(subscriptionId: subscriptionId, territory: territory, planType: .upfront, mode: .freeTrial,
                                      duration: newDuration, numberOfPeriods: 1, startDate: day, endDate: nil, pricePointId: nil)
            items.append(PlannedItem(seq: seq, cell: cell, payload: .endIntro(ascId: current.ascId, endDate: day),
                                     before: .intro(current: current, future: nil), target: .intro(current: ended, future: nil), rules: ["I7"]))
            items.append(PlannedItem(seq: seq + 1, cell: cell, payload: .createIntro(offer),
                                     before: .intro(current: ended, future: nil), target: .intro(current: ended, future: created),
                                     dependsOn: [seq], rules: ["I7"]))
            seq += 2
        }
        return items
    }

    /// A CANARY intro Draft for the items (verdicts are recomputed by the preflight).
    public static func draft(items: [PlannedItem], subscriptionId: String, baseSyncId: Int64) throws -> PlanDraft {
        let spec = PlanSpec.intro(IntroPlanSpec(subscriptionIds: [subscriptionId], mode: .freeTrial, duration: .twoWeeks, numberOfPeriods: 1,
                                                pricing: .freeTrial, startDate: nil, endDate: nil, nominalDiscount: nil,
                                                filter: PlanFilter(productAscIds: [subscriptionId]), canary: true))
        return PlanDraft(spec: spec, items: items, excluded: [], verdicts: [], checkDiffs: [],
                         estimate: Estimate(requests: items.count * 2, minutes: 1), baseSyncId: baseSyncId,
                         planHash: try PlanHasher.hash(items), verdictHash: PolicyEngine.hash([]), confirmationLevel: .c0)
    }
}
#endif
