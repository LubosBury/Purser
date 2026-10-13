import Foundation
import Domain

/// The predefined import table of a workspace: country, currency and one regular-price column per subscription.
/// `mapping` and `csv` describe the same layout, so a filled template imports without any hand-written mapping.
public enum ImportTemplate {
    public struct Product: Hashable, Sendable {
        public var ascId: String
        public var productId: String
        public init(ascId: String, productId: String) {
            self.ascId = ascId; self.productId = productId
        }
    }

    /// Column A = country, B = currency, C onwards = regular price (UPFRONT) of `products` in order; data from row 2.
    public static func mapping(products: [Product], version: Int) -> ImportMapping {
        ImportMapping(version: version, source: .csv, firstDataRow: 2, countryColumn: "A", currencyColumn: "B",
                      targets: products.enumerated().map { index, product in
                          ImportTarget(column: ImportColumns.letters(for: index + 2), productAscId: product.ascId,
                                       kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: true)
                      })
    }

    /// RFC 4180 text (CRLF): a header and one row per territory, sorted by storefront name, with today's prices filled in
    /// where `prices[ascId][territory]` has one. Territories the bundled name map does not know are returned in
    /// `skipped` instead of being written under a guessed name.
    public static func csv(products: [Product], territories: [TerritoryCode: CurrencyCode],
                           prices: [String: [TerritoryCode: Decimal]]) throws -> (text: String, skipped: [TerritoryCode]) {
        let names = try TerritoryNameMap.bundledStorefrontNames()
        var lines = [(["Country", "Currency"] + products.map(\.productId)).map(field).joined(separator: ",")]
        var skipped: [TerritoryCode] = []
        let named = territories.keys.compactMap { code -> (String, TerritoryCode)? in
            guard let name = names[code] else { skipped.append(code); return nil }
            return (name, code)
        }
        for (name, code) in named.sorted(by: { $0.0 < $1.0 }) {
            let cells = [name, territories[code]?.rawValue ?? ""] + products.map { prices[$0.ascId]?[code].map { "\($0)" } ?? "" }
            lines.append(cells.map(field).joined(separator: ","))
        }
        return (lines.joined(separator: "\r\n") + "\r\n", skipped.sorted())
    }

    private static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
