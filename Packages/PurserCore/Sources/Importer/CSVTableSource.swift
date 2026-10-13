import Foundation

public enum CSVError: Error, Equatable {
    case notUTF8
    case unterminatedQuote(line: Int)
}

/// RFC 4180 CSV (comma separated): quoted fields, escaped quotes (""), CRLF / LF / CR line ends,
/// line breaks inside quoted fields and an optional UTF-8 BOM.
public struct CSVTableSource: TableSource {
    private let data: Data

    public init(data: Data) { self.data = data }

    public func fetchRows() async throws -> [[String]] { try Self.parse(data) }

    static func parse(_ data: Data) throws -> [[String]] {
        guard let decoded = String(data: data, encoding: .utf8) else { throw CSVError.notUTF8 }
        var scalars = Array(decoded.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var fieldTouched = false
        var inQuotes = false
        var line = 1
        var quoteStartLine = 1
        var i = 0

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            fieldTouched = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    if c == "\n" || (c == "\r" && !(i + 1 < scalars.count && scalars[i + 1] == "\n")) { line += 1 }
                    field.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "\"":
                if field.isEmpty {
                    inQuotes = true
                    quoteStartLine = line
                    fieldTouched = true
                } else {
                    field.append(c)
                }
            case ",":
                endField()
            case "\r":
                endRow()
                line += 1
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
            case "\n":
                endRow()
                line += 1
            default:
                field.append(c)
                fieldTouched = true
            }
            i += 1
        }
        if inQuotes { throw CSVError.unterminatedQuote(line: quoteStartLine) }
        if fieldTouched || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
