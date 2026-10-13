import Foundation
import Store
import Background

/// Where workspaces live (K2): the App Group container in a signed build, Application Support in an unsigned one.
/// The same root M0's AppEnvironment used; M4 only adds the one-time move out of the unsigned fallback root.
enum AppPaths {
    enum RootStatus: Equatable, Sendable {
        case appGroup
        case legacyNoGroup
        case migrationFailed(String)
    }

    /// M0's fallback root (AppEnvironment without an App Group): Application Support/Purser.
    static func legacyWorkspacesRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Purser", isDirectory: true)
    }

    /// Computed once per process, before any workspace database is opened.
    static let workspaces: (root: URL, status: RootStatus) = prepareWorkspacesRoot()

    private static func prepareWorkspacesRoot() -> (root: URL, status: RootStatus) {
        let legacy = legacyWorkspacesRoot()
        guard let groupRoot = GroupPaths.groupWorkspacesRoot() else { return (legacy, .legacyNoGroup) }
        guard groupRoot.standardizedFileURL != legacy.standardizedFileURL else { return (groupRoot, .appGroup) }
        do {
            _ = try WorkspaceRootMigration.migrate(from: legacy, to: groupRoot)
            return (groupRoot, .appGroup)
        } catch {
            // The move is resumable: the next launch continues where this one stopped.
            return (groupRoot, .migrationFailed(String(describing: error)))
        }
    }
}
