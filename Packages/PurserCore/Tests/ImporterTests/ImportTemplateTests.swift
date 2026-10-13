import Foundation
import Testing
import Domain
import Importer

@Suite struct ImportTemplateTests {
    private let yearly = ImportTemplate.Product(ascId: "6500000001", productId: "fruit.yearly")
    private let monthly = ImportTemplate.Product(ascId: "6500000002", productId: "fruit.monthly")
    private let territories: [TerritoryCode: CurrencyCode] = ["USA": "USD", "KOR": "KRW", "CZE": "CZK"]
    private let prices: [String: [TerritoryCode: Decimal]] = [
        "6500000001": ["USA": Decimal(string: "29.99")!, "KOR": Decimal(39000), "CZE": Decimal(799)],
        "6500000002": ["USA": Decimal(string: "3.99")!],
    ]

    @Test func mappingHasOneWrittenRegularPriceColumnPerProduct() {
        let mapping = ImportTemplate.mapping(products: [yearly, monthly], version: 4)
        #expect(mapping.version == 4)
        #expect(mapping.source == .csv)
        #expect(mapping.firstDataRow == 2)
        #expect(mapping.countryColumn == "A")
        #expect(mapping.currencyColumn == "B")
        #expect(mapping.targets == [
            ImportTarget(column: "C", productAscId: "6500000001", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: true),
            ImportTarget(column: "D", productAscId: "6500000002", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: true),
        ])
    }

    @Test func csvHasAHeaderAndOneRowPerTerritoryWithCurrentPrices() async throws {
        let template = try ImportTemplate.csv(products: [yearly, monthly], territories: territories, prices: prices)
        #expect(template.skipped.isEmpty)
        let rows = try await CSVTableSource(data: Data(template.text.utf8)).fetchRows()
        #expect(rows[0] == ["Country", "Currency", "fruit.yearly", "fruit.monthly"])
        #expect(rows.count == 4)
        #expect(rows.contains(["Korea, Republic of", "KRW", "39000", ""]))
        #expect(rows.contains(["United States", "USD", "29.99", "3.99"]))
    }

    @Test func aFilledTemplateImportsCleanlyWithItsMapping() async throws {
        let template = try ImportTemplate.csv(products: [yearly], territories: territories, prices: prices)
        let (table, verdicts) = try await Importer(names: try TerritoryNameMap.bundled()).importTable(
            source: CSVTableSource(data: Data(template.text.utf8)),
            mapping: ImportTemplate.mapping(products: [yearly], version: 1), territories: territories)
        #expect(verdicts.isEmpty, "\(verdicts.map(\.message))")
        #expect(table.rows.count == 3)
        #expect(table.row(for: "KOR")?.values["C"]?.amount == Decimal(39000))
    }

    @Test func territoriesWithoutAStorefrontNameAreReportedNotGuessed() throws {
        let template = try ImportTemplate.csv(products: [yearly], territories: ["USA": "USD", "ZZZ": "USD"], prices: [:])
        #expect(template.skipped == ["ZZZ"])
        #expect(template.text.split(separator: "\r\n").count == 2)
    }
}
