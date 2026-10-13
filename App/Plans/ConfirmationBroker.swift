import Foundation
import Observation
import Executor

/// Bridges the executor's async `confirm` callback to the confirmation sheet.
@MainActor @Observable
final class ConfirmationBroker {
    struct Pending: Identifiable {
        let id = UUID()
        let request: ConfirmationRequest
    }

    var pending: Pending?
    private var continuation: CheckedContinuation<ConfirmationResponse, Never>?

    func ask(_ request: ConfirmationRequest) async -> ConfirmationResponse {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = Pending(request: request)
        }
    }

    func answer(_ response: ConfirmationResponse) {
        pending = nil
        continuation?.resume(returning: response)
        continuation = nil
    }

    /// Sheet closed without a button (Esc), host view gone (lock, workspace switch) or app locked: treated as Cancel,
    /// so the plan returns to Draft with 0 writes and the executor never hangs on a parked continuation.
    func cancelIfWaiting() {
        guard continuation != nil else { return }
        answer(ConfirmationResponse(accepted: false, acknowledgedExclusions: false, typedAppName: nil, reason: nil, checkedRiskClasses: []))
    }
}
