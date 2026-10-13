import CryptoKit
import Foundation
import Domain

public struct Importer: Sendable {
    private let names: TerritoryNameMap

    public init(names: TerritoryNameMap) { self.names = names }

    /// Applies rules S1-S3; returns the table and the verdicts (block verdicts mean the table must not be planned).
    public func importTable(source: any TableSource, mapping: ImportMapping,
                            territories: [TerritoryCode: CurrencyCode]) async throws -> (ImportedTable, [Verdict]) {
        let raw = try await source.fetchRows()
        return Self.process(raw: raw, mapping: mapping, territories: territories, names: names)
    }

    static func process(raw: [[String]], mapping: ImportMapping, territories: [TerritoryCode: CurrencyCode],
                        names: TerritoryNameMap) -> (ImportedTable, [Verdict]) {
        var verdicts: [Verdict] = []
        let sha = sha256(of: raw)

        guard let countryIndex = ImportColumns.index(of: mapping.countryColumn) else {
            verdicts.append(block("S1", "The country column “\(mapping.countryColumn)” is not a valid column letter."))
            return (ImportedTable(mappingVersion: mapping.version, sha256: sha, rows: [], rawRows: raw), verdicts)
        }
        guard let currencyIndex = ImportColumns.index(of: mapping.currencyColumn) else {
            verdicts.append(block("S2", "The currency column “\(mapping.currencyColumn)” is not a valid column letter."))
            return (ImportedTable(mappingVersion: mapping.version, sha256: sha, rows: [], rawRows: raw), verdicts)
        }
        var targetColumns: [(target: ImportTarget, index: Int)] = []
        var badColumns: [String] = []
        for target in mapping.targets {
            if let index = ImportColumns.index(of: target.column) { targetColumns.append((target, index)) } else { badColumns.append(target.column) }
        }
        if !badColumns.isEmpty {
            verdicts.append(block("S3", "Invalid target columns: \(badColumns.joined(separator: ", "))."))
        }

        var unknown: [String] = []
        var currencyIssues: [String] = []
        var valueIssues: [String] = []
        var rowsByCode: [TerritoryCode: [Int]] = [:]
        var rows: [ImportedRow] = []

        let firstIndex = max(mapping.firstDataRow, 1) - 1
        for index in raw.indices where index >= firstIndex {
            let cells = raw[index]
            let rowNumber = index + 1
            func cell(_ column: Int) -> String {
                column < cells.count ? cells[column].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            if cells.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }

            let name = cell(countryIndex)
            guard let code = names.code(for: name) else {
                unknown.append("row \(rowNumber) (“\(name.isEmpty ? "empty" : name)”)")
                continue
            }
            guard let expectedCurrency = territories[code] else {
                unknown.append("row \(rowNumber) (“\(name)” = \(code), does not exist in ASC)")
                continue
            }
            rowsByCode[code, default: []].append(rowNumber)

            let currency = CurrencyCode(cell(currencyIndex))
            if currency != expectedCurrency {
                currencyIssues.append("row \(rowNumber) \(code): \(currency.rawValue.isEmpty ? "empty" : currency.rawValue) ≠ \(expectedCurrency)")
            }

            var values: [String: ImportedValue] = [:]
            for (target, columnIndex) in targetColumns {
                let text = cell(columnIndex)
                let column = target.column.uppercased()
                if text.isEmpty && !target.writes { continue }
                if let value = parse(text, kind: target.kind) {
                    values[column] = value
                } else {
                    valueIssues.append("row \(rowNumber) column \(column): “\(text)”")
                }
            }
            rows.append(ImportedRow(rowNumber: rowNumber, territory: code, currency: currency, values: values))
        }

        let duplicates = rowsByCode.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
            .map { "\($0.key) on rows \($0.value.map(String.init).joined(separator: ", "))" }
        if !unknown.isEmpty {
            verdicts.append(block("S1", "Unknown territory name: \(list(unknown))."))
        }
        if !duplicates.isEmpty {
            verdicts.append(block("S1", "The territory is in the table more than once: \(list(duplicates))."))
        }
        if !currencyIssues.isEmpty {
            verdicts.append(block("S2", "The currency does not match the territory's currency in ASC: \(list(currencyIssues))."))
        }
        if !valueIssues.isEmpty {
            verdicts.append(block("S3", "The value is not an unformatted number > 0 (for a trial, a duration or a number of days): \(list(valueIssues))."))
        }
        return (ImportedTable(mappingVersion: mapping.version, sha256: sha, rows: rows, rawRows: raw), verdicts)
    }

    static func parse(_ text: String, kind: TargetKind) -> ImportedValue? {
        if case .introFreeTrial = kind { return ImportValueParser.trialDuration(text).map { .duration($0) } }
        return ImportValueParser.amount(text).map { .amount($0) }
    }

    static func sha256(of raw: [[String]]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(raw)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func block(_ rule: RuleID, _ message: String) -> Verdict {
        Verdict(rule: rule, severity: .block(.plan), cell: nil, message: message)
    }

    static func list(_ items: [String], limit: Int = 20) -> String {
        let head = items.prefix(limit).joined(separator: "; ")
        return items.count > limit ? "\(head); … and \(items.count - limit) more" : head
    }
}
