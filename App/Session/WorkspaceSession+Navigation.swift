import Foundation

extension WorkspaceSession {
    /// K11 (M4): switches the workspace window to the Plan screen with plan `id` (delegates to `planning`).
    /// Inside the Plans screen PlanningModel opens plans itself (`build(_:reason:)`, list selection).
    func showPlan(id: String) {
        let planning = self.planning
        Task {
            // The snapshot is reloaded after every sync; decoding it again here was most of the wait.
            if planning.snapshot == nil { await planning.reload() }
            await planning.open(planId: id)
        }
    }
}
