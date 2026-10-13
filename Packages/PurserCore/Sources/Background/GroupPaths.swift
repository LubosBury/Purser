import Foundation

/// App Group and keychain access group come from Info.plist keys filled at build time with
/// $(TeamIdentifierPrefix) / $(AppIdentifierPrefix). Unsigned builds have no usable group.
public enum GroupPaths {
    public static let appGroupInfoKey = "PurserAppGroup"
    public static let keychainGroupInfoKey = "PurserKeychainGroup"
    /// K2 registry root inside the group container; the same path M0's AppEnvironment.registryRoot uses.
    public static let workspacesSubpath = "Library/Application Support/Purser"

    public static func appGroupIdentifier(bundle: Bundle = .main) -> String? {
        normalized(bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String)
    }

    public static func keychainAccessGroup(bundle: Bundle = .main) -> String? {
        normalized(bundle.object(forInfoDictionaryKey: keychainGroupInfoKey) as? String)
    }

    public static func workspacesRoot(inGroupContainer container: URL) -> URL {
        container.appendingPathComponent(workspacesSubpath, isDirectory: true)
    }

    /// `<group container>/Library/Application Support/Purser`, or nil when the group container is unavailable.
    public static func groupWorkspacesRoot(bundle: Bundle = .main) -> URL? {
        guard let group = appGroupIdentifier(bundle: bundle),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return workspacesRoot(inGroupContainer: container)
    }

    /// A signed value starts with the team / app id prefix; "com.…" means the prefix expanded to nothing.
    static func normalized(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              !value.hasPrefix("com."), !value.contains("$(") else { return nil }
        return value
    }
}
