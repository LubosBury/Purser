import Foundation
import GRDB

/// One SQLite database per workspace (spec §4). Nothing is shared between workspaces.
public final class WorkspaceDatabase: Sendable {
    public let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Migrations.migrator.migrate(writer)
    }

    /// Creates `directory` if needed, opens `directory/purser.sqlite` (WAL, foreign keys on,
    /// `configuration.busyMode = .timeout(10)` because the app and the login item share the file) and runs migrations.
    public static func open(at directory: URL) throws -> WorkspaceDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("purser.sqlite").path
        return try WorkspaceDatabase(writer: DatabasePool(path: path, configuration: makeConfiguration()))
    }

    /// In-memory database with migrations applied (tests).
    public static func inMemory() throws -> WorkspaceDatabase {
        try WorkspaceDatabase(writer: DatabaseQueue(configuration: makeConfiguration()))
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        // From M4 the login item opens the same file; wait for its write lock instead of failing with SQLITE_BUSY.
        configuration.busyMode = .timeout(10)
        configuration.label = "purser.workspace"
        return configuration
    }
}

public enum StoreError: Error, Equatable, Sendable {
    /// A column holds a value the current code cannot map back to a type.
    case corruptValue(table: String, column: String, value: String)
    /// The database already belongs to another workspace (rule D3).
    case workspaceMismatch(stored: UUID, attempted: UUID)
}
