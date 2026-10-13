import Foundation
import GRDB
import Store

public struct OfferCodeRegistryEntry: Hashable, Sendable, Identifiable {
    public var offerCode: String
    public var productAscId: String
    public var firstSeenSync: Int64
    public var id: String { offerCode }

    public init(offerCode: String, productAscId: String, firstSeenSync: Int64) {
        self.offerCode = offerCode; self.productAscId = productAscId; self.firstSeenSync = firstSeenSync
    }
}

/// Read-only view of offer_code_registry (rule O1) for the registry screen.
public struct OfferCodeRegistryReader: Sendable {
    let database: WorkspaceDatabase

    public init(database: WorkspaceDatabase) { self.database = database }

    public func entries() throws -> [OfferCodeRegistryEntry] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT offer_code, product_asc_id, first_seen_sync FROM offer_code_registry ORDER BY offer_code")
                .map { row in
                    OfferCodeRegistryEntry(offerCode: row["offer_code"], productAscId: row["product_asc_id"],
                                           firstSeenSync: row["first_seen_sync"])
                }
        }
    }
}
