import Testing
import GRDB
import Store
import Catalog

@Suite struct OfferCodeRegistryReaderTests {
    @Test func listsEveryCodeSortedByCode() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO offer_code_registry (offer_code, product_asc_id, first_seen_sync) VALUES (?, ?, ?)",
                           arguments: ["winter_v1", "sub-2", 7])
            try db.execute(sql: "INSERT INTO offer_code_registry (offer_code, product_asc_id, first_seen_sync) VALUES (?, ?, ?)",
                           arguments: ["spring_v1", "sub-1", 3])
        }
        let entries = try OfferCodeRegistryReader(database: database).entries()
        #expect(entries == [
            OfferCodeRegistryEntry(offerCode: "spring_v1", productAscId: "sub-1", firstSeenSync: 3),
            OfferCodeRegistryEntry(offerCode: "winter_v1", productAscId: "sub-2", firstSeenSync: 7),
        ])
    }
}
