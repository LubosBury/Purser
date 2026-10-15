import Foundation

/// One row of a localization table: a product (Product ID, ASC id, or group:<reference name>), a locale
/// and the desired texts. nil = the cell was empty: keep the current text (L-D3).
public struct LocalizationTableRow: Hashable, Sendable {
    public var rowNumber: Int
    public var product: String
    public var locale: String
    public var name: String?
    public var description: String?
    public var customAppName: String?

    public init(rowNumber: Int = 0, product: String, locale: String, name: String? = nil, description: String? = nil,
                customAppName: String? = nil) {
        self.rowNumber = rowNumber; self.product = product; self.locale = locale
        self.name = name; self.description = description; self.customAppName = customAppName
    }
}

public enum LocalizationTableError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case missingColumn(String)
    case unknownColumn(String)
    case duplicateColumn(String)
    case missingValue(row: Int, column: String)

    public var description: String {
        switch self {
        case .empty: return "The table is empty."
        case let .missingColumn(name): return "The table has no column “\(name)”; the header is \(LocalizationTable.header.joined(separator: ", "))."
        case let .unknownColumn(name): return "The column “\(name)” is not one of \(LocalizationTable.header.joined(separator: ", "))."
        case let .duplicateColumn(name): return "The column “\(name)” is in the header twice."
        case let .missingValue(row, column): return "Row \(row) has no \(column)."
        }
    }
}

/// The localization table (CSV or Google Sheet): a header row, then one row per product or group and locale.
public enum LocalizationTable {
    public static let header = ["product", "locale", "name", "description", "custom_app_name"]

    /// Reads rows the way a TableSource returns them. The first non-empty row is the header (any order, any case);
    /// product and locale are required in every data row; empty rows are skipped; cells are trimmed, an empty cell is nil.
    public static func parse(_ rows: [[String]]) throws -> [LocalizationTableRow] {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let headerIndex = rows.firstIndex(where: { $0.contains { !clean($0).isEmpty } }) else { throw LocalizationTableError.empty }
        var columns: [String: Int] = [:]
        for (index, raw) in rows[headerIndex].enumerated() {
            let name = clean(raw).lowercased()
            if name.isEmpty { continue }
            guard header.contains(name) else { throw LocalizationTableError.unknownColumn(clean(raw)) }
            guard columns[name] == nil else { throw LocalizationTableError.duplicateColumn(name) }
            columns[name] = index
        }
        for required in ["product", "locale"] where columns[required] == nil { throw LocalizationTableError.missingColumn(required) }
        var result: [LocalizationTableRow] = []
        for index in rows.indices where index > headerIndex {
            let cells = rows[index]
            if cells.allSatisfy({ clean($0).isEmpty }) { continue }
            func value(_ column: String) -> String? {
                guard let position = columns[column], position < cells.count else { return nil }
                let text = clean(cells[position])
                return text.isEmpty ? nil : unguarded(text)
            }
            let rowNumber = index + 1
            guard let product = value("product") else { throw LocalizationTableError.missingValue(row: rowNumber, column: "product") }
            guard let locale = value("locale") else { throw LocalizationTableError.missingValue(row: rowNumber, column: "locale") }
            result.append(LocalizationTableRow(rowNumber: rowNumber, product: product, locale: locale, name: value("name"),
                                               description: value("description"), customAppName: value("custom_app_name")))
        }
        return result
    }

    /// RFC 4180 text with CRLF line ends: the header and the rows (an empty cell for nil). A text a spreadsheet would read as
    /// a formula (it starts with =, +, -, @, a tab or a carriage return) is written with a leading apostrophe; `parse` removes it.
    public static func csv(_ rows: [LocalizationTableRow]) -> String {
        var lines = [header.joined(separator: ",")]
        for row in rows {
            lines.append([row.product, row.locale, row.name ?? "", row.description ?? "", row.customAppName ?? ""].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func field(_ text: String) -> String {
        let text = guarded(text)
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // CSV formula injection: a spreadsheet reads a cell that starts with one of these as a formula. An export prefixes such
    // a text with an apostrophe (spreadsheets show it as plain text) and an import takes that apostrophe off again. A text
    // that already starts with apostrophes before such a character gets one more, so that nothing is lost on the way back;
    // an apostrophe in front of anything else is part of the text and stays.
    private static let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    private static func apostrophesLeadToFormula(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.drop(while: { $0 == "'" }).first else { return false }
        return formulaStarts.contains(first)
    }

    private static func guarded(_ text: String) -> String {
        apostrophesLeadToFormula(text) ? "'" + text : text
    }

    private static func unguarded(_ text: String) -> String {
        guard text.unicodeScalars.first == "'", apostrophesLeadToFormula(text) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.dropFirst()))
    }
}
