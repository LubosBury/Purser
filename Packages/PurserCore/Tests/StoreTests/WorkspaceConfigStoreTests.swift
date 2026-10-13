import Foundation
import Testing
import Domain
import Store
import PurserTestSupport

@Suite struct WorkspaceConfigStoreTests {
    @Test func savesAndLoadsTheConfig() throws {
        let database = try WorkspaceDatabase.inMemory()
        let store = WorkspaceConfigStore(database: database)
        #expect(try store.load() == nil)
        var config = Sample.config()
        try database.writer.write { db in try store.save(config, at: Sample.fixedNow, in: db) }
        #expect(try store.load() == config)
        config.isProduction = true
        try database.writer.write { db in try store.save(config, at: Sample.fixedNow, in: db) }
        #expect(try store.load()?.isProduction == true)
    }

    @Test func refusesAConfigOfAnotherWorkspace() throws {
        let database = try WorkspaceDatabase.inMemory()
        let store = WorkspaceConfigStore(database: database)
        try database.writer.write { db in try store.save(Sample.config(), at: Sample.fixedNow, in: db) }
        var other = Sample.config()
        other.id = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
        #expect(throws: StoreError.workspaceMismatch(stored: Sample.workspaceId, attempted: other.id)) {
            try database.writer.write { db in try store.save(other, at: Sample.fixedNow, in: db) }
        }
    }
}
