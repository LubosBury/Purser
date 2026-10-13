import Foundation
import Domain
import Catalog
import Importer
import Planner
import MCPBridge

/// The workspace's import table in the layout of its saved mapping, filled with what is live today. Unlike the app's
/// template it never changes the mapping, so a hand-made mapping (intro, promo, check-only columns) survives.
public enum ImportTableExport {
    public struct Result: Hashable, Sendable {
        public var text: String
        /// Territories the bundled name map does not know; they are left out instead of written under a guessed name.
        public var skipped: [TerritoryCode]
        public var emptyCells: Int
    }

    public static func csv(mapping: ImportMapping, snapshot: CatalogSnapshot, today: CalendarDate) throws -> Result {
        guard let country = ImportColumns.index(of: mapping.countryColumn), let currency = ImportColumns.index(of: mapping.currencyColumn) else {
            throw ToolArgumentError("The import mapping has an invalid country or currency column; fix it in the app.")
        }
        let targets = mapping.targets.compactMap { target in ImportColumns.index(of: target.column).map { (target, $0) } }
        let width = ([country, currency] + targets.map(\.1)).max().map { $0 + 1 } ?? 2
        let names = try TerritoryNameMap.bundledStorefrontNames()

        var header = [String](repeating: "", count: width)
        header[country] = "Country"
        header[currency] = "Currency"
        for (target, index) in targets {
            let product = snapshot.subscriptions[target.productAscId]?.productId ?? snapshot.iaps[target.productAscId]?.productId ?? target.productAscId
            header[index] = "\(product) \(label(target.kind))" + (target.writes ? "" : " (check only)")
        }
        // The header sits on the row above the first data row; rows above it stay empty.
        var lines = [[String]](repeating: [String](repeating: "", count: width), count: max(mapping.firstDataRow - 2, 0))
        if mapping.firstDataRow >= 2 { lines.append(header) }

        var skipped: [TerritoryCode] = []
        var emptyCells = 0
        let named = snapshot.territories.keys.compactMap { code -> (String, TerritoryCode)? in
            guard let name = names[code] else { skipped.append(code); return nil }
            return (name, code)
        }
        for (name, code) in named.sorted(by: { $0.0 < $1.0 }) {
            var row = [String](repeating: "", count: width)
            row[country] = name
            row[currency] = snapshot.territories[code]?.rawValue ?? ""
            for (target, index) in targets {
                row[index] = liveValue(target, territory: code, snapshot: snapshot, today: today) ?? ""
                if row[index].isEmpty, target.writes { emptyCells += 1 }
            }
            lines.append(row)
        }
        return Result(text: lines.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n",
                      skipped: skipped.sorted(), emptyCells: emptyCells)
    }

    static func label(_ kind: TargetKind) -> String {
        switch kind {
        case let .regularPrice(planType): return planType == .upfront ? "regular" : "regular \(planType.rawValue)"
        case let .introPayUpFront(duration): return "intro PAY_UP_FRONT \(duration.rawValue)"
        case let .introPayAsYouGo(duration, periods): return "intro PAY_AS_YOU_GO \(periods)x\(duration.rawValue)"
        case .introFreeTrial: return "intro FREE_TRIAL"
        case let .promoPrice(offerCode): return "promo \(offerCode)"
        case .iapManualPrice: return "manual price"
        }
    }

    /// What the column would have to hold to change nothing.
    static func liveValue(_ target: ImportTarget, territory: TerritoryCode, snapshot: CatalogSnapshot, today: CalendarDate) -> String? {
        let product = target.productAscId
        switch target.kind {
        case let .regularPrice(planType):
            return snapshot.currentRegular(subscriptionId: product, territory: territory, planType: planType, on: today).map { "\($0.customerPrice)" }
        case .introPayUpFront, .introPayAsYouGo, .introFreeTrial:
            guard let intro = snapshot.currentIntro(subscriptionId: product, territory: territory, planType: .upfront, on: today) else { return nil }
            switch (target.kind, intro.mode) {
            case (.introFreeTrial, .freeTrial): return intro.duration.rawValue
            case (.introPayUpFront, .payUpFront), (.introPayAsYouGo, .payAsYouGo): return intro.customerPrice.map { "\($0)" }
            default: return nil
            }
        case let .promoPrice(offerCode):
            return snapshot.promoOffers.first { $0.subscriptionId == product && $0.offerCode == offerCode }?
                .prices.first { $0.territory == territory }?.customerPrice.map { "\($0)" }
        case .iapManualPrice:
            return ImportChecks.currentManualPrices(iapId: product, snapshot: snapshot, today: today)[territory].map { "\($0)" }
        }
    }

    private static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// What a table would do beyond the prices it names; create_import_plan reports these with the plan.
public enum ImportChecks {
    public struct RemovedManualPrice: Hashable, Sendable {
        public var iapId: String
        public var territory: TerritoryCode
        public var price: Decimal
    }

    static func currentManualPrices(iapId: String, snapshot: CatalogSnapshot, today: CalendarDate) -> [TerritoryCode: Decimal] {
        var prices: [TerritoryCode: Decimal] = [:]
        for price in snapshot.iapSchedules[iapId]?.manualPrices ?? [] where (price.startDate.map { $0 <= today } ?? true) && (price.endDate.map { today < $0 } ?? true) {
            prices[price.territory] = price.customerPrice
        }
        return prices
    }

    /// An in-app purchase column replaces the whole schedule: a territory that has a manual price today and no value
    /// in the table (an empty cell, a missing row, a territory outside the filter) loses it and follows the base
    /// territory again.
    public static func removedManualPrices(spec: ImportPlanSpec, mapping: ImportMapping, snapshot: CatalogSnapshot,
                                           today: CalendarDate) -> [RemovedManualPrice] {
        let written = Set(spec.writeColumns.map { $0.uppercased() })
        let rows = spec.table.rows.filter { spec.filter.includes(territory: $0.territory) }
        var removed: [RemovedManualPrice] = []
        for target in mapping.targets where target.writes && written.contains(target.column.uppercased()) && spec.filter.includes(product: target.productAscId) {
            guard case .iapManualPrice = target.kind else { continue }
            let given = Set(rows.filter { $0.values[target.column.uppercased()]?.amount != nil }.map(\.territory))
            for (territory, price) in currentManualPrices(iapId: target.productAscId, snapshot: snapshot, today: today) where !given.contains(territory) {
                removed.append(RemovedManualPrice(iapId: target.productAscId, territory: territory, price: price))
            }
        }
        return removed.sorted { ($0.iapId, $0.territory) < ($1.iapId, $1.territory) }
    }

    /// Territories of the catalog that have no row in the table; nothing is planned for them.
    public static func territoriesWithoutARow(table: ImportedTable, snapshot: CatalogSnapshot) -> [TerritoryCode] {
        Set(snapshot.territories.keys).subtracting(table.rows.map(\.territory)).sorted()
    }

    public static func report(spec: ImportPlanSpec, mapping: ImportMapping, snapshot: CatalogSnapshot, today: CalendarDate,
                              productName: (String) -> String) -> JSONValue {
        let removed = removedManualPrices(spec: spec, mapping: mapping, snapshot: snapshot, today: today)
        let missing = territoriesWithoutARow(table: spec.table, snapshot: snapshot)
        var report: [String: JSONValue] = [
            "rows_read": MCPRender.number(spec.table.rows.count),
            "territories_without_a_row": .array(missing.map { .string($0.rawValue) }),
            "iap_manual_prices_removed": .array(removed.map {
                ["product": .string(productName($0.iapId)), "territory": .string($0.territory.rawValue), "current_price": MCPRender.number($0.price)]
            }),
        ]
        if !removed.isEmpty {
            report["warning"] = "This table removes manual prices of an in-app purchase: an IAP column replaces the whole schedule. Put the current price in the cell to keep it."
        }
        return .object(report)
    }
}
