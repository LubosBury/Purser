import Foundation
import Synchronization

/// A controllable clock: `now()` returns the stored date, `sleep(_:)` advances it instead of waiting.
public final class ManualClock: Sendable {
    private let state: Mutex<Date>
    private let sleeps = Mutex<[Duration]>([])

    public init(_ start: Date) {
        state = Mutex(start)
    }

    public func now() -> Date {
        state.withLock { $0 }
    }

    public func advance(by seconds: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    public func set(_ date: Date) {
        state.withLock { $0 = date }
    }

    public func sleep(_ duration: Duration) async throws {
        sleeps.withLock { $0.append(duration) }
        let components = duration.components
        advance(by: Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    /// Every duration passed to `sleep(_:)`, in order.
    public var recordedSleeps: [Duration] {
        sleeps.withLock { $0 }
    }
}
