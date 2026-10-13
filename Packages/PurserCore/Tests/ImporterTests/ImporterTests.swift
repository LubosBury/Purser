import Foundation
import Testing
import Domain
import Importer
import PurserTestSupport

@Suite struct ImporterTests {
    let territories: [TerritoryCode: CurrencyCode] = ["CZE": "CZK", "USA": "USD", "DEU": "EUR", "KOR": "KRW", "CIV": "XOF"]

    func mapping(_ targets: [ImportTarget]) -> ImportMapping {
        ImportMapping(version: 3, source: .csv, firstDataRow: 2, countryColumn: "A", currencyColumn: "B", targets: targets)
    }
    let price = ImportTarget(column: "C", productAscId: "sub-1", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: true)
    let trial = ImportTarget(column: "D", productAscId: "sub-1", kind: .introFreeTrial, nominalDiscount: nil, writes: true)

    func run(_ rows: [[String]], targets: [ImportTarget]? = nil) async throws -> (ImportedTable, [Verdict]) {
        let importer = Importer(names: try TerritoryNameMap.bundled())
        return try await importer.importTable(source: StaticTableSource(rows), mapping: mapping(targets ?? [price, trial]), territories: territories)
    }

    @Test func validRowsProduceValuesAndNoVerdicts() async throws {
        let (table, verdicts) = try await run([
            ["Country", "Currency", "Price", "Trial"],
            ["Czech Republic", "CZK", "249", "7"],
            ["Korea, Republic of", "KRW", "14900", "ONE_MONTH"],
            ["Côte d’Ivoire", "xof", "4.99", "one_week"],
            ["", "", "", ""],
        ])
        #expect(verdicts.isEmpty)
        #expect(table.mappingVersion == 3)
        #expect(table.rows.map(\.territory) == ["CZE", "KOR", "CIV"])
        #expect(table.rows.map(\.rowNumber) == [2, 3, 4])
        #expect(table.rows[0].values["C"] == .amount(Decimal(249)))
        #expect(table.rows[0].values["D"] == .duration(.oneWeek))
        #expect(table.rows[1].values["D"] == .duration(.oneMonth))
        #expect(table.rows[2].values["C"] == .amount(Decimal(string: "4.99")!))
        #expect(table.rows[2].currency == "XOF")
    }

    @Test func unknownTerritoryBlocksPlanAndListsRows() async throws {
        let (_, verdicts) = try await run([
            ["Country", "Currency", "Price", "Trial"],
            ["Czech Republic", "CZK", "249", "7"],
            ["Narnia", "NRN", "1", "7"],
            ["", "USD", "1", "7"],
        ])
        let s1 = try #require(verdicts.first { $0.rule == "S1" })
        #expect(s1.severity == .block(.plan))
        #expect(s1.message.contains("row 3 (“Narnia”)"))
        #expect(s1.message.contains("row 4 (“empty”)"))
    }

    @Test func territoryNotInASCIsUnknown() async throws {
        let (_, verdicts) = try await run([["h"], ["Japan", "JPY", "100", "7"]])
        #expect(verdicts.contains { $0.rule == "S1" && $0.message.contains("JPN, does not exist in ASC") })
    }

    @Test func duplicateTerritoryBlocks() async throws {
        let (_, verdicts) = try await run([
            ["h"], ["United States", "USD", "1", "7"], ["USA", "USD", "2", "7"],
        ])
        #expect(verdicts.contains { $0.rule == "S1" && $0.severity == .block(.plan) && $0.message.contains("USA on rows 2, 3") })
    }

    @Test func currencyMismatchBlocks() async throws {
        let (_, verdicts) = try await run([["h"], ["Czech Republic", "EUR", "249", "7"]])
        let s2 = try #require(verdicts.first { $0.rule == "S2" })
        #expect(s2.severity == .block(.plan))
        #expect(s2.message.contains("row 2 CZE: EUR ≠ CZK"))
    }

    @Test(arguments: ["1,99", "$1.99", "1 000", "0", "-1", "abc", "1e3", ""])
    func formattedOrNonPositiveNumbersBlock(_ text: String) async throws {
        let (table, verdicts) = try await run([["h"], ["Germany", "EUR", text, "7"]])
        #expect(verdicts.contains { $0.rule == "S3" && $0.severity == .block(.plan) })
        #expect(table.rows.first?.values["C"] == nil)
    }

    @Test(arguments: ["5", "7.5", "TEN_DAYS", "0"])
    func invalidTrialLengthBlocks(_ text: String) async throws {
        let (_, verdicts) = try await run([["h"], ["Germany", "EUR", "9.99", text]])
        #expect(verdicts.contains { $0.rule == "S3" && $0.message.contains("column D") })
    }

    @Test func trialDayCountsMapToDurations() async throws {
        let rows: [[String]] = [["h"]] + [("3", "THREE_DAYS"), ("14", "TWO_WEEKS"), ("30", "ONE_MONTH"), ("60", "TWO_MONTHS"),
                                          ("90", "THREE_MONTHS"), ("180", "SIX_MONTHS"), ("365", "ONE_YEAR")]
            .enumerated().map { i, pair in [["Czech Republic", "United States", "Germany", "Korea, Republic of", "Côte d’Ivoire", "Czechia", "USA"][i], "", "1", pair.0] }
        let (table, _) = try await run(rows, targets: [trial])
        #expect(table.rows.compactMap { $0.values["D"]?.duration?.rawValue } == ["THREE_DAYS", "TWO_WEEKS", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"])
    }

    @Test func emptyCheckOnlyCellIsSkippedButEmptyWriteCellBlocks() async throws {
        let checkOnly = ImportTarget(column: "C", productAscId: "sub-1", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: false)
        let (table, verdicts) = try await run([["h"], ["Germany", "EUR", "", ""]], targets: [checkOnly])
        #expect(verdicts.isEmpty)
        #expect(table.rows.first?.values.isEmpty == true)
        let (_, writeVerdicts) = try await run([["h"], ["Germany", "EUR", "", ""]], targets: [price])
        #expect(writeVerdicts.contains { $0.rule == "S3" })
    }

    @Test func invalidColumnLettersBlock() async throws {
        let bad = ImportTarget(column: "C1", productAscId: "sub-1", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: true)
        let (_, verdicts) = try await run([["h"], ["Germany", "EUR", "1"]], targets: [bad])
        #expect(verdicts.contains { $0.rule == "S3" && $0.message.contains("C1") })
    }

    @Test func sha256IsStableAndCoversRawRows() async throws {
        let rows = [["h"], ["Germany", "EUR", "9.99", "7"]]
        let (a, _) = try await run(rows)
        let (b, _) = try await run(rows)
        let (c, _) = try await run([["h"], ["Germany", "EUR", "9.98", "7"]])
        #expect(a.sha256 == b.sha256)
        #expect(a.sha256 != c.sha256)
        #expect(a.sha256.count == 64)
        #expect(a.rawRows == rows)
    }

    @Test func synthetic175FixtureImportsCleanlyAgainstRecordedTerritories() async throws {
        let importer = Importer(names: try TerritoryNameMap.bundled())
        let (table, verdicts) = try await importer.importTable(
            source: CSVTableSource(data: try SyntheticImport.csvData()),
            mapping: SyntheticImport.mapping(),
            territories: try RepoFiles.ascTerritories())
        #expect(verdicts.isEmpty, "\(verdicts.map(\.message))")
        #expect(table.rows.count == 175)
        #expect(Set(table.rows.map(\.territory)).count == 175)
        #expect(table.row(for: "KOR")?.values["C"] != nil)
        #expect(table.row(for: "CIV")?.values["D"] != nil)
        #expect(table.rows.allSatisfy { $0.values.count == 7 })
    }
}
