import Foundation

/// Files under Packages/PurserCore/Tests/Fixtures, read straight from the source tree.
public enum Fixtures {
    public static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // TestSupport
            .deletingLastPathComponent()     // Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    public static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relativePath))
    }

    /// Fixtures/asc/<name>.json
    public static func asc(_ name: String) throws -> Data {
        try data("asc/\(name).json")
    }
}
