import AppKit

/// Captures the launch time for heartbeat-aware recovery; Cmd-Q during apply pauses the plan with QUIT before the app exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = ProcessLaunch.date
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = ApplyController.current, controller.isRunning else { return .terminateNow }
        Task { @MainActor in
            await controller.pauseForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
