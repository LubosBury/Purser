import Foundation

public struct WorkspaceEntry: Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var directoryName: String        // relative to the registry root

    public init(id: UUID, name: String, colorHex: String, directoryName: String) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.directoryName = directoryName
    }
}

/// workspaces.json in the app container: only id, name, colour and directory (spec §4).
public struct WorkspaceRegistry: Sendable {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var fileURL: URL { root.appendingPathComponent("workspaces.json") }

    public func list() throws -> [WorkspaceEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONCoding.decoder.decode([WorkspaceEntry].self, from: Data(contentsOf: fileURL))
    }

    public func create(name: String, colorHex: String) throws -> WorkspaceEntry {
        var entries = try list()
        let id = UUID()
        let entry = WorkspaceEntry(id: id, name: name, colorHex: colorHex, directoryName: "ws-\(id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: directory(for: entry), withIntermediateDirectories: true)
        entries.append(entry)
        try JSONCoding.encoder.encode(entries).write(to: fileURL, options: .atomic)
        return entry
    }

    public func directory(for entry: WorkspaceEntry) -> URL {
        root.appendingPathComponent(entry.directoryName, isDirectory: true)
    }
}
