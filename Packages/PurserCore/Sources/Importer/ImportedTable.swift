import Foundation
import Domain

public enum ImportedValue: Hashable, Sendable, Codable {
    case amount(Decimal)
    case duration(OfferDuration)

    public var amount: Decimal? { if case let .amount(a) = self { return a } else { return nil } }
    public var duration: OfferDuration? { if case let .duration(d) = self { return d } else { return nil } }
}

public struct ImportedRow: Hashable, Sendable, Codable {
    public var rowNumber: Int
    public var territory: TerritoryCode
    public var currency: CurrencyCode
    public var values: [String: ImportedValue]   // keyed by target column letters

    public init(rowNumber: Int, territory: TerritoryCode, currency: CurrencyCode, values: [String: ImportedValue]) {
        self.rowNumber = rowNumber; self.territory = territory; self.currency = currency; self.values = values
    }
}

public struct ImportedTable: Hashable, Sendable, Codable {
    public var mappingVersion: Int
    public var sha256: String                // over the raw rows
    public var rows: [ImportedRow]
    public var rawRows: [[String]]

    public init(mappingVersion: Int, sha256: String, rows: [ImportedRow], rawRows: [[String]]) {
        self.mappingVersion = mappingVersion; self.sha256 = sha256; self.rows = rows; self.rawRows = rawRows
    }

    public func row(for territory: TerritoryCode) -> ImportedRow? { rows.first { $0.territory == territory } }
}
