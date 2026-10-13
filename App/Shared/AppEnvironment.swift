import Foundation
import PurserSecurity

/// Everything the app needs from the machine: where workspaces live, the Keychain and Touch ID.
struct AppEnvironment: Sendable {
    var registryRoot: URL
    var secretStore: any SecretStore
    var gate: any BiometricGate
    /// For diagnostics only (spike SK): the access group the Keychain store uses, nil = default group.
    var keychainAccessGroup: String?

    static func live() -> AppEnvironment {
        let group = keychainAccessGroup()
        return AppEnvironment(registryRoot: AppPaths.workspaces.root, secretStore: KeychainSecretStore(accessGroup: group),
                              gate: LocalAuthenticationGate(), keychainAccessGroup: group)
    }

    /// "TEAMID.com.lubosbury.purser.shared" in a signed build; nil (default group) in an unsigned one.
    private static func keychainAccessGroup() -> String? {
        guard let group = infoValue("PurserKeychainGroup"), group != "com.lubosbury.purser.shared" else { return nil }
        return group
    }

    private static func infoValue(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
