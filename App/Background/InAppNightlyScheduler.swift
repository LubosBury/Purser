import Foundation
import Background

extension Notification.Name {
    static let purserNightlySyncFinished = Notification.Name("com.lubosbury.purser.nightlySyncFinished")
}

final class BackgroundActivityCompletion: @unchecked Sendable {
    private let completion: NSBackgroundActivityScheduler.CompletionHandler
    init(_ completion: @escaping NSBackgroundActivityScheduler.CompletionHandler) { self.completion = completion }
    func finish() { completion(.finished) }
}

/// Fallback while the app runs (spec §4: "the sync runs at launch and periodically while the app runs").
@MainActor
final class InAppNightlyScheduler {
    private var activity: NSBackgroundActivityScheduler?

    var isActive: Bool { activity != nil }

    func start(runner: NightlySyncRunner) {
        guard activity == nil else { return }
        let activity = NSBackgroundActivityScheduler(identifier: "com.lubosbury.purser.nightly-sync")
        activity.repeats = true
        activity.interval = 60 * 60
        activity.tolerance = 10 * 60
        activity.qualityOfService = .utility
        activity.schedule { completion in
            let done = BackgroundActivityCompletion(completion)
            Task.detached {
                _ = await runner.runOnce()
                await MainActor.run { NotificationCenter.default.post(name: .purserNightlySyncFinished, object: nil) }
                done.finish()
            }
        }
        self.activity = activity
        Task.detached {
            _ = await runner.runOnce()
            await MainActor.run { NotificationCenter.default.post(name: .purserNightlySyncFinished, object: nil) }
        }
    }

    func stop() {
        activity?.invalidate()
        activity = nil
    }
}
