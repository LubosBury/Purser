import Foundation
import Synchronization

/// Simulated time: `sleepFunction` advances the clock instead of waiting.
public final class TestClock: Sendable {
    private let current: Mutex<Date>

    public init(_ start: Date) { current = Mutex(start) }

    public static func at(_ iso: String) -> TestClock {
        TestClock(ISO8601DateFormatter().date(from: iso)!)
    }

    public func now() -> Date { current.withLock { $0 } }

    public func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    public var nowFunction: @Sendable () -> Date { { [self] in self.now() } }

    public var sleepFunction: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            try Task.checkCancellation()
            let parts = duration.components
            self.advance(by: Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
    }
}
