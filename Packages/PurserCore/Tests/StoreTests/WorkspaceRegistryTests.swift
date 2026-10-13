import Foundation
import Testing
import Store
import PurserTestSupport

@Suite struct WorkspaceRegistryTests {
    @Test func emptyRegistryListsNothing() throws {
        let registry = WorkspaceRegistry(root: try makeTemporaryDirectory())
        #expect(try registry.list().isEmpty)
    }

    @Test func createPersistsEntriesWithSeparateDirectories() throws {
        let root = try makeTemporaryDirectory()
        let registry = WorkspaceRegistry(root: root)
        let first = try registry.create(name: "Fruit Journal", colorHex: "#2E7D32")
        let second = try registry.create(name: "Veggie Planner", colorHex: "#C62828")

        #expect(first.id != second.id)
        #expect(first.directoryName == "ws-\(first.id.uuidString.lowercased())")
        #expect(registry.directory(for: first) != registry.directory(for: second))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: registry.directory(for: first).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let reloaded = try WorkspaceRegistry(root: root).list()
        #expect(reloaded == [first, second])
    }

    @Test func registryFileHoldsOnlyIdNameColourAndDirectory() throws {
        let root = try makeTemporaryDirectory()
        _ = try WorkspaceRegistry(root: root).create(name: "Fruit Journal", colorHex: "#2E7D32")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("workspaces.json"))) as? [[String: Any]]
        #expect(json?.first.map { Set($0.keys) } == ["id", "name", "colorHex", "directoryName"])
    }
}
