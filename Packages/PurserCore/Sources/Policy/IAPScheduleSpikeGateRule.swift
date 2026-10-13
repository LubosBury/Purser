import Foundation
import Domain
import Catalog

/// Temporary spike gate (K8, rule id "S10"): SCHEDULE_REPLACE items that replace a live schedule stay blocked until spike S10 confirmed that
/// POST /v1/inAppPurchasePriceSchedules replaces the whole schedule. Not the STRUCT rule L1.
public struct IAPScheduleSpikeGateRule: PlanRule {
    public let id: RuleID = "S10"
    let confirmed: Bool

    public init(confirmed: Bool = AppleConstants.iapScheduleReplaceConfirmed) { self.confirmed = confirmed }

    public func evaluate(_ context: PolicyContext) -> [Verdict] {
        // The first schedule of a product that has none replaces nothing, so the open S10 question does not apply to it.
        let replacesLiveSchedule = context.items.contains { item in
            guard item.op == .scheduleReplace else { return false }
            if case .iapSchedule(nil) = item.before { return false }
            return true
        }
        guard !confirmed, replacesLiveSchedule else { return [] }
        return [Verdict(rule: id, severity: .block(.plan), cell: nil,
                        message: "Writing an IAP schedule is blocked until spike S10 confirms that POST replaces the whole schedule.")]
    }
}
