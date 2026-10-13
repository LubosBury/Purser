import Foundation
import Domain
import Importer

/// Mapping and helpers for Tests/Fixtures/import/synthetic-175.csv (invented products Alpha, Beta, Gamma).
public enum SyntheticImport {
    public static let alpha = "sub-alpha"
    public static let beta = "sub-beta"
    public static let gamma = "sub-gamma"
    public static let regularColumns: [String: String] = ["C": alpha, "E": beta, "G": gamma]
    public static let introColumns: [String: String] = ["D": alpha, "F": beta, "H": gamma]

    /// Intro columns D/F/H write PAY_UP_FRONT ONE_YEAR (-20 %), regular columns C/E/G are check-only,
    /// trial column I is check-only.
    public static func mapping(introWrites: Bool = true, regularWrites: Bool = false) -> ImportMapping {
        var targets: [ImportTarget] = []
        for (column, product) in regularColumns.sorted(by: { $0.key < $1.key }) {
            targets.append(ImportTarget(column: column, productAscId: product, kind: .regularPrice(planType: .upfront),
                                        nominalDiscount: nil, writes: regularWrites))
        }
        for (column, product) in introColumns.sorted(by: { $0.key < $1.key }) {
            targets.append(ImportTarget(column: column, productAscId: product, kind: .introPayUpFront(duration: .oneYear),
                                        nominalDiscount: Decimal(string: "0.20")!, writes: introWrites))
        }
        targets.append(ImportTarget(column: "I", productAscId: alpha, kind: .introFreeTrial, nominalDiscount: nil, writes: false))
        return ImportMapping(version: 1, source: .csv, firstDataRow: 2, countryColumn: "A", currencyColumn: "B", targets: targets)
    }

    public static func csvData() throws -> Data { try RepoFiles.fixtureData("import/synthetic-175.csv") }

    /// Territory -> currency taken from the CSV itself (hermetic planner tests).
    public static func currencies() throws -> [TerritoryCode: CurrencyCode] {
        let names = try TerritoryNameMap.bundled()
        let rows = try parseCSVLines(String(decoding: try csvData(), as: UTF8.self))
        var result: [TerritoryCode: CurrencyCode] = [:]
        for row in rows.dropFirst() where row.count >= 2 {
            if let code = names.code(for: row[0]) { result[code] = CurrencyCode(row[1]) }
        }
        return result
    }

    /// Imports the fixture with `mapping()`; currencies come from the CSV.
    public static func importedTable(mapping: ImportMapping = SyntheticImport.mapping()) async throws -> (ImportedTable, [Verdict]) {
        let importer = Importer(names: try TerritoryNameMap.bundled())
        return try await importer.importTable(source: CSVTableSource(data: try csvData()), mapping: mapping, territories: try currencies())
    }

    private static func parseCSVLines(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            if line.hasPrefix("\"") {
                let close = line.dropFirst().firstIndex(of: "\"")!
                let name = String(line[line.index(after: line.startIndex)..<close])
                let rest = line[line.index(after: close)...].split(separator: ",").map(String.init)
                rows.append([name] + rest)
            } else {
                rows.append(line.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
            }
        }
        return rows
    }
}

/// In-memory TableSource for tests.
public struct StaticTableSource: TableSource {
    public var rows: [[String]]
    public init(_ rows: [[String]]) { self.rows = rows }
    public func fetchRows() async throws -> [[String]] { rows }
}
