import Foundation

/// Keeps the Mac awake while an apply runs (spec §4 "during an apply the app does not let the Mac sleep").
@MainActor
final class KeepAwake {
    private var token: (any NSObjectProtocol)?

    func begin(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: reason)
    }

    func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }
}
