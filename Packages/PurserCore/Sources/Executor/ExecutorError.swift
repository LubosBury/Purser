import Domain
import Catalog

public enum ExecutorError: Error, Equatable, Sendable {
    case planNotFound(String)
    case invalidState(PlanState)
    case anotherPlanApplying(String)
    /// Rule A1: plan binding differs from the workspace config ("config") or from live GET /v1/apps ("live").
    case bindingMismatch(String)
    case syncIncomplete(SyncStatus)
    case noSnapshot
    case corruptPlan(String)
    case unknownProduct(String)
    /// Plan-level BLOCK verdicts found by a resume preflight.
    case blocked([RuleID])
    case freshTableRequired
    case nothingToWithdraw
    case reasonRequired
}
