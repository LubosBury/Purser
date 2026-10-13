import Foundation
import Domain

/// Planner-level verdicts that are not rules from the spec use this id.
enum PlannerRule {
    static let plan: RuleID = "PLAN"
}

/// Errors that stop building a plan; Planner.plan turns them into a BLOCK·PLAN verdict on an empty draft.
public enum PlanningError: Error, Equatable, Sendable {
    case preserveChoiceMissing(increases: Int)
    case missingImportMapping
    case missingReferencedPlan(String)

    var verdict: Verdict {
        switch self {
        case let .preserveChoiceMissing(increases):
            return Verdict(rule: "R1", severity: .block(.plan), cell: nil,
                           message: "R1 preserve choice missing: the plan contains \(increases) regular price increases; choose preserveCurrentPrice.")
        case .missingImportMapping:
            return Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: nil, message: "The workspace has no import mapping.")
        case let .missingReferencedPlan(id):
            return Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: nil, message: "The items of plan \(id) are not available.")
        }
    }
}
