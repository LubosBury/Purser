import Foundation

public enum WorkspaceRootMigrationOutcome: Equatable, Sendable {
    case nothingToMigrate
    case alreadyMigrated
    case migrated(count: Int)
}

public enum WorkspaceRootMigrationError: Error, Equatable {
    case conflict(String)
}

/// K2 (M4): moves workspaces.json and every workspace directory from the unsigned fallback root
/// (Application Support/Purser) to the App Group root (<group>/Library/Application Support/Purser), so the
/// login item can see them (spec §4). Run before any database is opened. Crash-safe and idempotent:
/// directories move first, workspaces.json last (commit point), then a marker is written into the fallback root.
/// Nothing is copied, merged or deleted.
public enum WorkspaceRootMigration {
    public static let registryFileName = "workspaces.json"
    public static let markerFileName = "MIGRATED_TO_APP_GROUP"

    public static func migrate(from legacyRoot: URL, to newRoot: URL,
                               fileManager: FileManager = .default) throws -> WorkspaceRootMigrationOutcome {
        let legacyRegistry = legacyRoot.appendingPathComponent(registryFileName)
        let newRegistry = newRoot.appendingPathComponent(registryFileName)
        guard fileManager.fileExists(atPath: legacyRegistry.path) else {
            let marker = legacyRoot.appendingPathComponent(markerFileName)
            return fileManager.fileExists(atPath: marker.path) ? .alreadyMigrated : .nothingToMigrate
        }
        if fileManager.fileExists(atPath: newRegistry.path) {
            throw WorkspaceRootMigrationError.conflict("Both \(legacyRegistry.path) and \(newRegistry.path) exist")
        }
        let entries = try WorkspaceRegistry(root: legacyRoot).list()
        try fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
        for entry in entries {
            let from = legacyRoot.appendingPathComponent(entry.directoryName, isDirectory: true)
            let to = newRoot.appendingPathComponent(entry.directoryName, isDirectory: true)
            switch (fileManager.fileExists(atPath: from.path), fileManager.fileExists(atPath: to.path)) {
            case (true, false):
                try fileManager.moveItem(at: from, to: to)
            case (false, true):
                continue
            case (true, true):
                throw WorkspaceRootMigrationError.conflict("\(entry.directoryName) exists in both roots")
            case (false, false):
                throw WorkspaceRootMigrationError.conflict("\(entry.directoryName) is missing")
            }
        }
        try fileManager.moveItem(at: legacyRegistry, to: newRegistry)
        try Data(newRoot.path.utf8).write(to: legacyRoot.appendingPathComponent(markerFileName))
        return .migrated(count: entries.count)
    }
}
