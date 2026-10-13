import Foundation
import Synchronization
import Store

/// Databases the app already has open. The in-app nightly fallback reuses the session's DatabasePool instead of
/// opening a second pool on the same file; the login item process never registers anything and opens its own.
public final class OpenWorkspaceDatabases: Sendable {
    public static let shared = OpenWorkspaceDatabases()
    private let databases = Mutex<[String: WorkspaceDatabase]>([:])

    public init() {}

    public func register(_ database: WorkspaceDatabase, directory: URL) {
        databases.withLock { $0[Self.key(directory)] = database }
    }

    public func unregister(directory: URL) {
        databases.withLock { $0[Self.key(directory)] = nil }
    }

    public func database(for directory: URL) -> WorkspaceDatabase? {
        databases.withLock { $0[Self.key(directory)] }
    }

    static func key(_ directory: URL) -> String { directory.standardizedFileURL.path }
}
