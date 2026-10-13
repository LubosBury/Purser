import Foundation
import Domain
import Store

extension Executor {
    /// K10: launch recovery without a known launch time pauses every Applying plan that is not running here.
    public func recover(afterWake: Bool) async throws -> [String] {
        try await recover(afterWake: afterWake, launchedAt: .distantFuture)
    }

    /// Launch (afterWake == false): an Applying plan becomes Paused(CRASH) only when its heartbeat predates `launchedAt`
    /// (it belongs to an earlier process); a plan written by another Executor of this process keeps beating and is left alone.
    /// Wake: plans whose heartbeat is older than 3 heartbeats become Paused(SLEEP). A plan running in this actor stops with
    /// SLEEP at its next item boundary (wake only). Persisted RATE/NETWORK pauses count as running: they never resume on
    /// their own after their apply session, so they become CRASH/SLEEP and continue only through resume() with Touch ID.
    /// Returns the ids of every paused Applying plan (launch banner).
    public func recover(afterWake: Bool, launchedAt: Date) async throws -> [String] {
        let staleAfter = AppleConstants.heartbeatSeconds * 3
        let current = now()
        for plan in try store.plans(states: [.applying]) where plan.pauseReason == nil || plan.pauseReason?.resumesAutomatically == true {
            if running.contains(plan.id) {
                if afterWake { pauseRequests[plan.id] = .sleep }
                continue
            }
            let heartbeat = plan.heartbeatAt ?? plan.updatedAt
            let stale = afterWake ? current.timeIntervalSince(heartbeat) > staleAfter : heartbeat < launchedAt
            if stale {
                try setPlan(plan.id, to: .applying, pause: afterWake ? .sleep : .crash,
                            note: "recovered after \(afterWake ? "wake" : "launch"); heartbeat \(Int(current.timeIntervalSince(heartbeat))) s old")
            }
        }
        return try store.plans(states: [.applying]).filter { $0.pauseReason != nil }.map(\.id).sorted()
    }
}
