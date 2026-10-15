import Foundation
import Domain
import Catalog

/// Temporary spike gate (K8, rule id "S10"): SCHEDULE_REPLACE items that replace a live schedule stay blocked until spike S10 confirmed that
/// POST /v1/inAppPurchasePriceSchedules replaces the whole schedule. Not the STRUCT rule L1.
///
/// Exception S10a: a schedule with no manual prices whose base territory the plan keeps (or no schedule at all) has nothing a
/// POST could remove, so the item passes with a WARN. The exception must hold both for the planned `before` and for the
/// snapshot the rule runs on; the preflight re-syncs the product first, so a manual price that appeared since planning blocks again.
public struct IAPScheduleSpikeGateRule: PlanRule {
    public let id: RuleID = "S10"
    public static let exceptionId: RuleID = "S10a"
    let confirmed: Bool

    public init(confirmed: Bool = AppleConstants.iapScheduleReplaceConfirmed) { self.confirmed = confirmed }

    public func evaluate(_ context: PolicyContext) -> [Verdict] {
        guard !confirmed else { return [] }
        var exempt: [(cell: CellKey, base: TerritoryCode)] = []
        var replacesLiveSchedule = false
        for item in context.items where item.op == .scheduleReplace {
            guard case let .replaceIAPSchedule(target) = item.payload,
                  case let .iapSchedule(before) = item.before,
                  case let .iapSchedule(live) = context.snapshot.cellState(item.cell, on: context.today),
                  Self.replacesNothing(before, target: target), Self.replacesNothing(live, target: target) else {
                replacesLiveSchedule = true
                continue
            }
            exempt.append((item.cell, target.baseTerritory))
        }
        var verdicts = exempt.map { cell, base in
            Verdict(rule: Self.exceptionId, severity: .warn, cell: cell,
                    message: "This in-app purchase has no manual prices and keeps base territory \(base.rawValue), so writing its schedule overwrites nothing (S10 exception).")
        }
        if replacesLiveSchedule {
            verdicts.append(Verdict(rule: id, severity: .block(.plan), cell: nil,
                                    message: "Writing an IAP schedule is blocked until spike S10 confirms that POST replaces the whole schedule."))
        }
        return verdicts
    }

    /// No schedule, or one without manual prices whose base territory the target keeps.
    static func replacesNothing(_ schedule: IAPSchedule?, target: NewIAPSchedule) -> Bool {
        guard let schedule else { return true }
        return schedule.manualPrices.isEmpty && schedule.baseTerritory == target.baseTerritory
    }
}
