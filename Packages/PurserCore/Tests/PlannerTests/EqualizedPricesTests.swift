import Foundation
import Testing
import Catalog
import Domain
import Importer
import Planner

@Suite struct EqualizedPricesTests {
    private func point(_ id: String, _ territory: TerritoryCode, _ price: String) -> PricePoint {
        PricePoint(id: id, productAscId: "s", territory: territory, planType: .upfront, customerPrice: Decimal(string: price)!, proceeds: nil)
    }

    @Test func basePointIsTheExactPriceInTheBaseTerritory() {
        let index = PricePointIndex([point("usa-29", "USA", "29.99"), point("usa-39", "USA", "39.99"), point("cze-29", "CZE", "29.99")])
        #expect(EqualizedPrices.basePoint(in: index, productAscId: "s", territory: "USA", planType: .upfront, amount: Decimal(string: "39.99")!)?.id == "usa-39")
        #expect(EqualizedPrices.basePoint(in: index, productAscId: "s", territory: "USA", planType: .upfront, amount: Decimal(string: "35")!) == nil)
        #expect(EqualizedPrices.basePoint(in: index, productAscId: "other", territory: "USA", planType: .upfront, amount: Decimal(string: "29.99")!) == nil)
    }

    @Test func tableHasOneLinePerTerritoryIncludingTheBaseAndParsesBack() throws {
        let text = EqualizedPrices.tableText(base: point("usa-29", "USA", "29.99"),
                                             equalized: [point("deu", "DEU", "29.99"), point("cze", "CZE", "799.0"), point("usa-dup", "USA", "31.99")])
        #expect(text == "CZE\t799\nDEU\t29.99\nUSA\t29.99")
        let parsed = PastedAmountTable.parse(text, names: TerritoryNameMap(entries: [:]), known: ["CZE", "DEU", "USA"])
        #expect(parsed.errors.isEmpty)
        #expect(parsed.amounts.map(\.territory) == ["CZE", "DEU", "USA"])
    }
}
