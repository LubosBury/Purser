import Foundation

/// A fresh, empty directory under the system temporary directory; each test gets its own.
public func makeTemporaryDirectory(_ label: String = "purser-tests") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(label, isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
