import Foundation
import Testing
import Domain
import Importer
import Planner

@Suite struct IAPImportExtractorTests {
    @Test func takesAmountsFromTheIAPColumnOfTheMapping() {
        let mapping = ImportMapping(version: 2, source: .csv, firstDataRow: 2, countryColumn: "A", currencyColumn: "B", targets: [
            ImportTarget(column: "C", productAscId: "sub-1", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: true),
            ImportTarget(column: "F", productAscId: "iap-1", kind: .iapManualPrice, nominalDiscount: nil, writes: true),
        ])
        let table = ImportedTable(mappingVersion: 2, sha256: "abc", rows: [
            ImportedRow(rowNumber: 2, territory: "USA", currency: "USD", values: ["C": .amount(Decimal(string: "39.99")!), "F": .amount(Decimal(string: "99.99")!)]),
            ImportedRow(rowNumber: 3, territory: "CZE", currency: "CZK", values: ["C": .amount(990), "F": .amount(2490)]),
            ImportedRow(rowNumber: 4, territory: "DEU", currency: "EUR", values: ["C": .amount(Decimal(string: "39.99")!)]),
        ], rawRows: [])
        #expect(IAPImportExtractor.amounts(from: table, mapping: mapping, iapId: "iap-1") == [
            TerritoryAmount(territory: "CZE", amount: 2490),
            TerritoryAmount(territory: "USA", amount: Decimal(string: "99.99")!),
        ])
        #expect(IAPImportExtractor.amounts(from: table, mapping: mapping, iapId: "iap-2").isEmpty)
    }
}
