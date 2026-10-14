import Foundation
import Domain
import Policy
import Executor

/// Thrown by the step hook in place of a process death.
public struct SimulatedCrash: Error {}

public enum CrashResumeError: Error, Equatable {
    case crashPointNotReached(ExecutorStep)
    case notRecovered([String])
}

extension ExecutorHarness {
    /// Applies `planId` until `crash`, then recovers and resumes once with a new executor, both under `policy`.
    public func crashAndResume(planId: String, at crash: ExecutorStep, policy: PolicyEngine = PolicyEngine()) async throws -> PlanState {
        let first = makeExecutor(policy: policy)
        await first.setStepHook { step in
            if step == crash { throw SimulatedCrash() }
        }
        do {
            _ = try await first.apply(planId: planId, confirm: Confirm.accept)
            throw CrashResumeError.crashPointNotReached(crash)
        } catch is SimulatedCrash {
        }
        clock.advance(by: AppleConstants.heartbeatSeconds * 4)
        let second = makeExecutor(policy: policy)
        let recovered = try await second.recover(afterWake: false)
        guard recovered == [planId] else { throw CrashResumeError.notRecovered(recovered) }
        return try await second.resume(planId: planId, confirm: Confirm.accept)
    }
}
