import Foundation
import Testing
import Domain
import Importer

/// The CSV layout produced by Tools/make-spike-csv.py must import cleanly with the M3 mapping.
@Suite struct SpikeCSVContractTests {
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // ImporterTests
        .deletingLastPathComponent()          // Tests
        .appendingPathComponent("Fixtures/import/spike-sample.csv")

    static let mapping = ImportMapping(
        version: 1, source: .csv, firstDataRow: 2, countryColumn: "A", currencyColumn: "B",
        targets: [
            ImportTarget(column: "C", productAscId: "sub-a", kind: .regularPrice(planType: .upfront),
                         nominalDiscount: nil, writes: false),
            ImportTarget(column: "D", productAscId: "sub-a", kind: .introPayUpFront(duration: .oneYear),
                         nominalDiscount: Decimal(string: "0.50")!, writes: true),
            ImportTarget(column: "E", productAscId: "sub-b", kind: .regularPrice(planType: .upfront),
                         nominalDiscount: nil, writes: false),
            ImportTarget(column: "F", productAscId: "sub-b", kind: .introPayUpFront(duration: .oneYear),
                         nominalDiscount: Decimal(string: "0.50")!, writes: true),
            ImportTarget(column: "G", productAscId: "sub-b", kind: .introFreeTrial,
                         nominalDiscount: nil, writes: true),
            ImportTarget(column: "H", productAscId: "sub-m", kind: .regularPrice(planType: .upfront),
                         nominalDiscount: nil, writes: true),
        ])

    static let names = TerritoryNameMap(entries: [
        "United States": "USA", "Czechia": "CZE", "Japan": "JPN",
        "Korea, Republic of": "KOR", "South Korea": "KOR",
    ])

    static let territories: [TerritoryCode: CurrencyCode] = ["USA": "USD", "CZE": "CZK", "JPN": "JPY", "KOR": "KRW"]

    func importSample() async throws -> (ImportedTable, [Verdict]) {
        let data = try #require(try? Data(contentsOf: Self.fixtureURL),
                                "missing \(Self.fixtureURL.path); generate it with Tools/make-spike-csv.py")
        return try await Importer(names: Self.names)
            .importTable(source: CSVTableSource(data: data), mapping: Self.mapping, territories: Self.territories)
    }

    @Test func generatedSpikeCSVImportsWithoutBlocks() async throws {
        let (table, verdicts) = try await importSample()
        let blocks = verdicts.filter { if case .block = $0.severity { return true } else { return false } }
        #expect(blocks.isEmpty, "unexpected blocks: \(blocks.map(\.message))")
        #expect(table.rows.map(\.territory).sorted() == ["CZE", "JPN", "KOR", "USA"])
    }

    @Test func generatedSpikeCSVValuesLandInTheirColumns() async throws {
        let (table, _) = try await importSample()
        let kor = try #require(table.rows.first { $0.territory == "KOR" })
        #expect(kor.currency == "KRW")
        #expect(kor.values["C"] == .amount(Decimal(string: "33000")!))
        #expect(kor.values["D"] == .amount(Decimal(string: "16500")!))
        #expect(kor.values["G"] == .duration(.oneMonth))
        let usa = try #require(table.rows.first { $0.territory == "USA" })
        #expect(usa.values["D"] == .amount(Decimal(string: "14.99")!))
        #expect(usa.values["F"] == .amount(Decimal(string: "19.99")!))
        #expect(usa.values["G"] == .duration(.oneWeek))
        #expect(usa.values["H"] == .amount(Decimal(string: "5.49")!))
        let jpn = try #require(table.rows.first { $0.territory == "JPN" })
        #expect(jpn.values["G"] == .duration(.twoWeeks))
        let cze = try #require(table.rows.first { $0.territory == "CZE" })
        #expect(cze.values["E"] == .amount(Decimal(string: "999")!))
        #expect(cze.values["H"] == .amount(Decimal(string: "141.90")!))
    }
}
