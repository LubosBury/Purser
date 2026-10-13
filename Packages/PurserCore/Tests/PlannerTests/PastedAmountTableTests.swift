import Foundation
import Testing
import Domain
import Importer
import Planner

@Suite struct PastedAmountTableTests {
    let names = TerritoryNameMap(entries: ["Czechia": "CZE", "Korea, Republic of": "KOR", "United States": "USA"])
    let known: Set<TerritoryCode> = ["CZE", "KOR", "USA", "DEU"]

    @Test func parsesCodesNamesTabsSemicolonsAndDecimalCommas() {
        let text = "USA\t4.99\nCzechia;129\nKorea, Republic of\t6500\nDEU 4,49\n\n"
        let (amounts, errors) = PastedAmountTable.parse(text, names: names, known: known)
        #expect(errors.isEmpty)
        #expect(amounts == [
            TerritoryAmount(territory: "CZE", amount: 129),
            TerritoryAmount(territory: "DEU", amount: Decimal(string: "4.49")!),
            TerritoryAmount(territory: "KOR", amount: 6500),
            TerritoryAmount(territory: "USA", amount: Decimal(string: "4.99")!),
        ])
    }

    @Test func reportsUnknownTerritoryBadAmountDuplicateAndMissingSeparator() {
        let text = "Atlantis\t5\nUSA\t12abc\nUSA\t0\nCZE\t10\nCZE\t11\nDEU"
        let (amounts, errors) = PastedAmountTable.parse(text, names: names, known: known)
        #expect(amounts == [TerritoryAmount(territory: "CZE", amount: 10)])
        #expect(errors.map(\.line) == [1, 2, 3, 5, 6])
    }
}
