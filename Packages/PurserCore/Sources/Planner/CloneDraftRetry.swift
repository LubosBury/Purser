import Foundation
import Domain
import Store

/// What a pass over the specs of a clone does with one of them: build its Draft, or report the plan that already carries
/// its title.
public enum CloneDraftAction: Equatable, Sendable {
    case build(title: String, spec: PlanSpec)
    case exists(CloneDraftOutcome.Line)
}

/// Preparing the drafts of a clone again is always safe (spec "Localizations and cloning" §6): a draft is saved with its
/// title as the plan's reason, so a pass skips every spec whose title a plan that has not ended already carries, and
/// builds the rest, including the drafts an earlier pass failed to build. A title holds the clone's Product ID, which
/// Apple never lets be used again, so it names one draft for good.
extension CloneDrafts {
    public static let draftExistsNote = "Draft already exists"
    /// For a plan with the draft's title that is no longer a Draft (Stale, being applied, scheduled or partly applied).
    public static let planExistsNote = "Plan already exists"

    /// Plan title (its reason) -> the plan for every plan that has not ended: a Draft, a Stale draft, one that is being
    /// applied, scheduled or partly applied. A cancelled, closed or effective plan does not stand in the way of a new Draft.
    /// When several plans carry a title, the newest is named.
    public static func openPlans(in plans: [StoredPlan]) -> [String: StoredPlan] {
        var open: [String: StoredPlan] = [:]
        for plan in plans.sorted(by: { $0.createdAt > $1.createdAt }) where !hasEnded(plan.state) {
            guard let title = plan.reason, open[title] == nil else { continue }
            open[title] = plan
        }
        return open
    }

    /// `openPlans` by plan id.
    public static func openDrafts(in plans: [StoredPlan]) -> [String: String] {
        openPlans(in: plans).mapValues(\.id)
    }

    /// The actions of a pass, in the order of the specs (the order to apply the drafts in). A spec whose title an open plan
    /// carries is reported with that plan: "Draft already exists" while it is a Draft, else "Plan already exists".
    public static func actions(for specs: [(title: String, spec: PlanSpec)], open: [String: StoredPlan]) -> [CloneDraftAction] {
        specs.map { draft in
            if let plan = open[draft.title] {
                return .exists(CloneDraftOutcome.Line(title: draft.title, planId: plan.id, error: nil,
                                                      note: plan.state == .draft ? draftExistsNote : planExistsNote))
            }
            return .build(title: draft.title, spec: draft.spec)
        }
    }

    private static func hasEnded(_ state: PlanState) -> Bool {
        switch state {
        case .effective, .closed, .cancelled: return true
        case .draft, .applying, .stale, .scheduled, .partiallyApplied: return false
        }
    }
}
