import Foundation

/// Remembers the last successful Touch ID so steps that follow each other (unlock, create workspace, open workspace)
/// ask once. Never used for applies or key changes: those always call the gate themselves.
public struct RecentAuthentication: Sendable {
    public static let defaultWindow: TimeInterval = 60

    private let window: TimeInterval
    private var lastSuccess: Date?

    public init(window: TimeInterval = RecentAuthentication.defaultWindow) {
        self.window = window
    }

    public mutating func noteSuccess(at date: Date) {
        lastSuccess = date
    }

    public mutating func invalidate() {
        lastSuccess = nil
    }

    public func covers(_ date: Date) -> Bool {
        guard let lastSuccess else { return false }
        let elapsed = date.timeIntervalSince(lastSuccess)
        return elapsed >= 0 && elapsed < window
    }
}
