import Foundation
import OSLog

/// DEBUG timing of opening a plan, from the click to the Plan screen's first frame. Read it with
/// `log stream --predicate 'subsystem == "com.lubosbury.purser" AND category == "plan-open"'`. Does nothing in Release.
enum PlanOpenTrace {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.lubosbury.purser", category: "plan-open")
    private static let start = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    #endif

    static func begin(_ planId: String) {
        #if DEBUG
        start.withLock { $0 = .now }
        logger.notice("begin \(planId, privacy: .public)")
        #endif
    }

    /// Logs `step` with the time since `begin`.
    static func mark(_ step: String) {
        #if DEBUG
        guard let start = start.withLock({ $0 }) else { return }
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        logger.notice("\(step, privacy: .public) +\(String(format: "%.0f", ms), privacy: .public) ms")
        #endif
    }

    /// Logs `step` once the view update that called it has been laid out and committed.
    @MainActor
    static func markAfterFrame(_ step: String) {
        #if DEBUG
        DispatchQueue.main.async { DispatchQueue.main.async { mark(step) } }
        #endif
    }
}
