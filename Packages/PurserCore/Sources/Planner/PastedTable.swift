import Foundation
import Domain
import Importer

/// Parses tables pasted into the New plan sheet: one "territory value" per line, separated by a tab, ";" or the last space.
/// The territory is an ASC code ("USA") or a storefront name ("Korea, Republic of").
public enum PastedTable {
    public static func amounts(_ text: String, names: TerritoryNameMap) -> (amounts: [TerritoryAmount], errors: [String]) {
        var amounts: [TerritoryAmount] = []
        var errors: [String] = []
        for (number, key, value) in lines(text) {
            guard let territory = territory(key, names: names) else { errors.append("row \(number): unknown territory “\(key)”"); continue }
            guard let amount = ImportValueParser.amount(value) else { errors.append("row \(number): “\(value)” is not a number > 0"); continue }
            amounts.append(TerritoryAmount(territory: territory, amount: amount))
        }
        return (amounts, errors)
    }

    public static func durations(_ text: String, names: TerritoryNameMap) -> (durations: [TerritoryCode: OfferDuration], errors: [String]) {
        var durations: [TerritoryCode: OfferDuration] = [:]
        var errors: [String] = []
        for (number, key, value) in lines(text) {
            guard let territory = territory(key, names: names) else { errors.append("row \(number): unknown territory “\(key)”"); continue }
            guard let duration = ImportValueParser.trialDuration(value) else { errors.append("row \(number): “\(value)” is not a trial duration"); continue }
            durations[territory] = duration
        }
        return (durations, errors)
    }

    /// Comma or whitespace separated territory codes / names; empty text = nil (all territories).
    public static func territories(_ text: String, names: TerritoryNameMap) -> (territories: Set<TerritoryCode>?, errors: [String]) {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return (nil, []) }
        var result: Set<TerritoryCode> = []
        var errors: [String] = []
        for part in parts {
            if let code = territory(part, names: names) { result.insert(code) } else { errors.append("unknown territory “\(part)”") }
        }
        return (result, errors)
    }

    static func territory(_ key: String, names: TerritoryNameMap) -> TerritoryCode? {
        if key.count == 3, key.allSatisfy({ $0.isASCII && $0.isUppercase }) { return TerritoryCode(key) }
        return names.code(for: key)
    }

    static func lines(_ text: String) -> [(Int, String, String)] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let key: Substring
            let value: Substring
            if let tab = line.lastIndex(of: "\t") {
                key = line[..<tab]; value = line[line.index(after: tab)...]
            } else if let semicolon = line.lastIndex(of: ";") {
                key = line[..<semicolon]; value = line[line.index(after: semicolon)...]
            } else if let space = line.lastIndex(of: " ") {
                key = line[..<space]; value = line[line.index(after: space)...]
            } else {
                return (index + 1, line, "")
            }
            return (index + 1, key.trimmingCharacters(in: .whitespaces), value.trimmingCharacters(in: .whitespaces))
        }
    }
}
