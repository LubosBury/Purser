import Foundation
import Domain

/// Locates files of the PurserCore package from tests without bundling them as resources.
public enum RepoFiles {
    /// Packages/PurserCore, derived from this file: Tests/TestSupport/RepoFiles.swift.
    public static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    public static func fixture(_ relativePath: String) -> URL {
        packageRoot.appendingPathComponent("Tests/Fixtures").appendingPathComponent(relativePath)
    }

    public static func fixtureData(_ relativePath: String) throws -> Data {
        try Data(contentsOf: fixture(relativePath))
    }

    public struct TerritoryNames: Sendable {
        public var storefronts: [String: TerritoryCode]
        public var aliases: [String: TerritoryCode]
    }

    /// Reads Sources/Importer/Resources/territory-names.json directly.
    public static func territoryNames() throws -> TerritoryNames {
        struct File: Decodable { var storefronts: [String: String]; var aliases: [String: String] }
        let url = packageRoot.appendingPathComponent("Sources/Importer/Resources/territory-names.json")
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return TerritoryNames(storefronts: file.storefronts.mapValues { TerritoryCode($0) },
                              aliases: file.aliases.mapValues { TerritoryCode($0) })
    }

    /// Territory -> currency from the recorded M0 fixture Tests/Fixtures/asc/territories.json
    /// (raw body of GET /v1/territories?limit=200).
    public static func ascTerritories() throws -> [TerritoryCode: CurrencyCode] {
        struct Document: Decodable {
            struct Resource: Decodable {
                struct Attributes: Decodable { var currency: String? }
                var id: String
                var attributes: Attributes?
            }
            var data: [Resource]
        }
        let document = try JSONDecoder().decode(Document.self, from: fixtureData("asc/territories.json"))
        var result: [TerritoryCode: CurrencyCode] = [:]
        for resource in document.data {
            if let currency = resource.attributes?.currency { result[TerritoryCode(resource.id)] = CurrencyCode(currency) }
        }
        return result
    }
}
