import Foundation
import Domain
import Importer

public struct PastedAmountLineError: Hashable, Sendable {
    public var line: Int
    public var message: String
    public init(line: Int, message: String) { self.line = line; self.message = message }
}

/// Two-column table pasted into a form: territory (ASC code or storefront name) and amount.
/// Separator: tab, else semicolon, else the last space. Amounts use "." or "," as decimal mark, no thousands separators.
public enum PastedAmountTable {
    public static func parse(_ text: String, names: TerritoryNameMap, known: Set<TerritoryCode>)
        -> (amounts: [TerritoryAmount], errors: [PastedAmountLineError]) {
        var amounts: [TerritoryAmount] = []
        var errors: [PastedAmountLineError] = []
        var seen = Set<TerritoryCode>()
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let number = index + 1
            guard let split = line.lastIndex(of: "\t") ?? line.lastIndex(of: ";") ?? line.lastIndex(of: " ") else {
                errors.append(PastedAmountLineError(line: number, message: "The separator between the territory and the amount is missing"))
                continue
            }
            let name = String(line[..<split]).trimmingCharacters(in: .whitespaces)
            let amountText = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
            let upper = name.uppercased()
            let territory = upper.count == 3 && known.contains(TerritoryCode(upper)) ? TerritoryCode(upper) : names.code(for: name)
            guard let territory, known.contains(territory) else {
                errors.append(PastedAmountLineError(line: number, message: "Unknown territory “\(name)”"))
                continue
            }
            guard amountText.wholeMatch(of: #/\d+(\.\d+)?/#) != nil,
                  let amount = Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX")), amount > 0 else {
                errors.append(PastedAmountLineError(line: number, message: "The amount “\(amountText)” is not a number greater than 0"))
                continue
            }
            guard seen.insert(territory).inserted else {
                errors.append(PastedAmountLineError(line: number, message: "The territory \(territory) is in the table twice"))
                continue
            }
            amounts.append(TerritoryAmount(territory: territory, amount: amount))
        }
        return (amounts.sorted { $0.territory < $1.territory }, errors)
    }
}
