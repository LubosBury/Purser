import Foundation
import Synchronization
import GRDB
import Domain

/// The price point index of one workspace database, kept while its price points stay the same.
///
/// The index holds every row of `price_point` (millions in a real workspace) and every snapshot needs it, so building
/// it for each snapshot made every snapshot cost seconds and gigabytes. The triggers on `price_point` bump
/// `price_point_generation` in the writer's transaction, so a reader that sees the generation the index was built at
/// sees exactly the rows it was built from, whichever process wrote them.
final class PricePointCache: Sendable {
    private let latest = Mutex<(generation: Int64, index: PricePointIndex)?>(nil)
    /// One build at a time: a reader that waited takes the index the other one built.
    private let building = Mutex(())

    /// The index of the price points `db` sees; call inside the read transaction of the snapshot that uses it.
    func index(_ db: Database) throws -> PricePointIndex {
        // Without the counter's row a change could not be told apart: build every time rather than risk a stale index.
        guard let generation = try Int64.fetchOne(db, sql: "SELECT value FROM price_point_generation") else {
            return try Self.load(db)
        }
        if let index = cached(generation) { return index }
        return try building.withLock { _ in
            if let index = cached(generation) { return index }
            let index = try Self.load(db)
            latest.withLock { latest in
                if (latest?.generation ?? .min) <= generation { latest = (generation, index) }
            }
            return index
        }
    }

    private func cached(_ generation: Int64) -> PricePointIndex? {
        latest.withLock { latest in latest?.generation == generation ? latest?.index : nil }
    }

    /// Streams the rows in the order of `price_point_lookup`, so only one ladder is held in memory at a time.
    static func load(_ db: Database) throws -> PricePointIndex {
        let posix = Locale(identifier: "en_US_POSIX")
        // A ladder repeats the same few thousand amounts in every product; each is parsed once.
        var amounts: [String: Decimal?] = [:]
        func amount(_ text: String) -> Decimal? {
            if let known = amounts[text] { return known }
            let value = Decimal(string: text, locale: posix)
            amounts[text] = value
            return value
        }

        var builder = PricePointIndex.Builder()
        var ladder: (product: String, territory: String, planType: String?)?
        var entries: [PricePointIndex.Entry] = []
        func flush() {
            guard let ladder else { return }
            builder.add(PricePointIndex.Key(productAscId: ladder.product, territory: TerritoryCode(ladder.territory),
                                            planType: ladder.planType.flatMap(PlanType.init(rawValue:))), entries)
            entries.removeAll(keepingCapacity: true)
        }

        let rows = try Row.fetchCursor(db, sql: """
            SELECT product_asc_id, territory, plan_type, id, customer_price, proceeds FROM price_point
            ORDER BY product_asc_id, territory, plan_type
            """)
        while let row = try rows.next() {
            let product: String = row[0]
            let territory: String = row[1]
            let planType: String? = row[2]
            if ladder?.product != product || ladder?.territory != territory || ladder?.planType != planType {
                flush()
                ladder = (product, territory, planType)
            }
            entries.append(PricePointIndex.Entry(id: row[3], customerPrice: amount(row[4]) ?? 0,
                                                 proceeds: (row[5] as String?).flatMap(amount)))
        }
        flush()
        return builder.build()
    }
}
