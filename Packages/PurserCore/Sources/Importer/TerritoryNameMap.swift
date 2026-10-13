import Foundation
import Domain

public enum TerritoryNameMapError: Error, Equatable {
    case resourceMissing
}

/// Shape of Resources/territory-names.json.
struct TerritoryNamesFile: Decodable {
    var version: Int
    var storefronts: [String: String]
    var aliases: [String: String]

    var allEntries: [String: TerritoryCode] {
        var result: [String: TerritoryCode] = [:]
        for (name, code) in storefronts { result[name] = TerritoryCode(code) }
        for (name, code) in aliases { result[name] = TerritoryCode(code) }
        return result
    }
}

/// Maps ASC storefront names (and common aliases) to ASC territory codes (rule S1).
public struct TerritoryNameMap: Sendable {
    private let entries: [String: TerritoryCode]

    /// Bundled Resources/territory-names.json: ASC storefront name -> TerritoryCode, plus aliases.
    public static func bundled() throws -> TerritoryNameMap {
        guard let url = Bundle.module.url(forResource: "territory-names", withExtension: "json") else {
            throw TerritoryNameMapError.resourceMissing
        }
        let file = try JSONDecoder().decode(TerritoryNamesFile.self, from: Data(contentsOf: url))
        return TerritoryNameMap(entries: file.allEntries)
    }

    /// ASC storefront name of every territory in the bundled file (code -> name), for generated tables.
    public static func bundledStorefrontNames() throws -> [TerritoryCode: String] {
        guard let url = Bundle.module.url(forResource: "territory-names", withExtension: "json") else {
            throw TerritoryNameMapError.resourceMissing
        }
        let file = try JSONDecoder().decode(TerritoryNamesFile.self, from: Data(contentsOf: url))
        var names: [TerritoryCode: String] = [:]
        for (name, code) in file.storefronts { names[TerritoryCode(code)] = name }
        return names
    }

    public init(entries: [String: TerritoryCode]) {
        var normalized: [String: TerritoryCode] = [:]
        for (name, code) in entries { normalized[Self.normalize(name)] = code }
        self.entries = normalized
    }

    /// NFC, typographic apostrophe -> ASCII, trimmed, inner whitespace collapsed, case-insensitive.
    public static func normalize(_ name: String) -> String {
        let nfc = name.precomposedStringWithCanonicalMapping
        let apostrophes = nfc
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
        let collapsed = apostrophes.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.lowercased()
    }

    public func code(for name: String) -> TerritoryCode? {
        entries[Self.normalize(name)]
    }
}
