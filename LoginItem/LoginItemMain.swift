import AppKit
import os
import UserNotifications
import Background

@main
enum LoginItemMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LoginItemDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class LoginItemDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let log = Logger(subsystem: "com.lubosbury.purser.LoginItem", category: "nightly")
    private var scheduler: LoginItemScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let root = GroupPaths.groupWorkspacesRoot() else {
            log.error("App Group container unavailable; nightly sync disabled")
            return
        }
        log.info("workspaces root: \(root.path, privacy: .public)")
        log.info("keychain group present: \(GroupPaths.keychainAccessGroup() != nil, privacy: .public)")
        UNUserNotificationCenter.current().delegate = self
        let runner = NightlySyncRunner.live(root: root, keychainAccessGroup: GroupPaths.keychainAccessGroup(),
                                            ledgerSuite: GroupPaths.appGroupIdentifier(), auditActor: "login-item")
        let scheduler = LoginItemScheduler(runner: runner, log: log)
        self.scheduler = scheduler
        Task {
            _ = await UserNotificationNightlyNotifier.requestAuthorization()
            scheduler.start()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { Self.openMainApp() }
    }

    /// The login item lives at Purser\ Pricing.app/Contents/Library/LoginItems/PurserLoginItem.app.
    static func openMainApp() {
        let mainApp = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: mainApp, configuration: NSWorkspace.OpenConfiguration())
    }
}
