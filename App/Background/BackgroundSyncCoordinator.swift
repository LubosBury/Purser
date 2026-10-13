import Foundation
import Observation
import ServiceManagement
import Domain
import Background

@MainActor @Observable
final class BackgroundSyncCoordinator {
    static let loginItemIdentifier = "com.lubosbury.purser.LoginItem"

    private let service = SMAppService.loginItem(identifier: BackgroundSyncCoordinator.loginItemIdentifier)
    private let fallback = InAppNightlyScheduler()
    private(set) var status: SMAppService.Status
    private(set) var lastError: String?
    private(set) var inAppActive = false

    init() {
        status = service.status
    }

    var loginItemEnabled: Bool { status == .enabled }

    /// The in-app fallback runs unless the login item is enabled and spike SL confirmed it works.
    var fallbackWanted: Bool { !(loginItemEnabled && AppleConstants.loginItemSyncConfirmed) }

    var statusText: String {
        switch status {
        case .enabled: return "On"
        case .notRegistered: return "Off"
        case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items"
        case .notFound: return "The login item is missing from the app bundle"
        @unknown default: return "Unknown state"
        }
    }

    var rootDescription: String {
        switch AppPaths.workspaces.status {
        case .appGroup: return "shared App Group container (Library/Application Support/Purser)"
        case .legacyNoGroup: return "the app's Application Support (unsigned build)"
        case let .migrationFailed(message): return "migration error: \(message)"
        }
    }

    /// Called once at launch and after every toggle.
    func refresh() {
        status = service.status
        if fallbackWanted {
            fallback.start(runner: NightlySyncRunner.live(root: AppPaths.workspaces.root,
                                                          keychainAccessGroup: GroupPaths.keychainAccessGroup(),
                                                          ledgerSuite: GroupPaths.appGroupIdentifier(), auditActor: "app-fallback"))
        } else {
            fallback.stop()
        }
        inAppActive = fallback.isActive
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
