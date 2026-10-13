import Foundation
import Testing
import GRDB
import Store

@Suite struct WorkspaceDatabaseConcurrencyTests {
    @Test func twoPoolsOnOneFileWriteWithoutBusyErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("purser-busy-\(UUID().uuidString)", isDirectory: true)
        let first = try WorkspaceDatabase.open(at: directory)
        let second = try WorkspaceDatabase.open(at: directory)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, database) in [first, second].enumerated() {
                group.addTask {
                    for n in 0..<200 {
                        try await database.writer.write { db in
                            try db.execute(sql: "INSERT INTO territory (code, currency) VALUES (?, ?)", arguments: ["T\(index)-\(n)", "USD"])
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        let count = try await first.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM territory") ?? 0 }
        #expect(count == 400)
    }
}
