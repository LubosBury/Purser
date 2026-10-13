import AppKit
import os
import Background

/// Checks every workspace at most every 15 minutes, at the nearest nightly slot, and right after wake.
@MainActor
final class LoginItemScheduler {
    private let runner: NightlySyncRunner
    private let log: Logger
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var running = false
    private var hoursUTC: [Int] = []

    init(runner: NightlySyncRunner, log: Logger) {
        self.runner = runner
        self.log = log
    }

    func start() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.runIfNeeded(reason: "wake") }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runIfNeeded(reason: "timer")
                let delay = NightlySchedule.nextCheckDelay(now: Date(), hoursUTC: self.hoursUTC)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        log.info("scheduler started")
    }

    func runIfNeeded(reason: String) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let reports = await runner.runOnce()
        hoursUTC = reports.compactMap(\.hourUTC)
        for report in reports {
            log.info("workspace \(report.workspaceId.uuidString, privacy: .public) [\(reason, privacy: .public)]: \(String(describing: report.outcome), privacy: .public) stale=\(report.staleNotified, privacy: .public)")
        }
    }
}
