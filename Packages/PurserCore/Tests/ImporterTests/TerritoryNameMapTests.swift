import Foundation
import Testing
import Domain
import Importer
import PurserTestSupport

@Suite struct TerritoryNameMapTests {
    @Test func bundledFileHas175StorefrontsWithUniqueCodes() throws {
        let names = try RepoFiles.territoryNames()
        #expect(names.storefronts.count == 175)
        #expect(Set(names.storefronts.values).count == 175)
        let map = try TerritoryNameMap.bundled()
        for (name, code) in names.storefronts {
            #expect(map.code(for: name) == code, "storefront \(name)")
        }
    }

    @Test func specialStorefrontCodes() throws {
        let map = try TerritoryNameMap.bundled()
        #expect(map.code(for: "Kosovo") == "XKS")
        #expect(map.code(for: "China mainland") == "CHN")
        #expect(map.code(for: "Macau") == "MAC")
        #expect(map.code(for: "Türkiye") == "TUR")
        #expect(map.code(for: "Eswatini") == "SWZ")
        #expect(map.code(for: "Micronesia") == "FSM")
        #expect(map.code(for: "Côte d’Ivoire") == "CIV")
        #expect(map.code(for: "São Tomé and Príncipe") == "STP")
        #expect(map.code(for: "Korea, Republic of") == "KOR")
        #expect(map.code(for: "Congo, Democratic Republic of the") == "COD")
        #expect(map.code(for: "Congo, Republic of the") == "COG")
    }

    @Test func normalizationHandlesNFCApostrophesCaseAndWhitespace() throws {
        let map = try TerritoryNameMap.bundled()
        #expect(map.code(for: "  united   states ") == "USA")
        #expect(map.code(for: "CÔTE D'IVOIRE") == "CIV")
        #expect(map.code(for: "Co\u{0302}te d\u{2019}Ivoire") == "CIV")
        #expect(map.code(for: "Sa\u{0303}o Tome\u{0301} and Pri\u{0301}ncipe") == "STP")
        #expect(map.code(for: "TÜRKIYE") == "TUR")
        #expect(TerritoryNameMap.normalize(" Côte d\u{2019}Ivoire ") == "côte d'ivoire")
    }

    @Test func everyAliasResolves() throws {
        let names = try RepoFiles.territoryNames()
        let map = try TerritoryNameMap.bundled()
        #expect(names.aliases.count >= 8)
        for (alias, code) in names.aliases {
            #expect(map.code(for: alias) == code, "alias \(alias)")
        }
        #expect(map.code(for: "South Korea") == "KOR")
        #expect(map.code(for: "Turkey") == "TUR")
        #expect(map.code(for: "Czechia") == "CZE")
        #expect(map.code(for: "USA") == "USA")
        #expect(map.code(for: "UK") == "GBR")
        #expect(map.code(for: "Ivory Coast") == "CIV")
        #expect(map.code(for: "Hong Kong SAR China") == "HKG")
        #expect(map.code(for: "Macao") == "MAC")
    }

    @Test func aliasesNeverPointToADifferentCodeThanAStorefront() throws {
        let names = try RepoFiles.territoryNames()
        let storefrontKeys = Dictionary(uniqueKeysWithValues: names.storefronts.map { (TerritoryNameMap.normalize($0.key), $0.value) })
        for (alias, code) in names.aliases {
            if let existing = storefrontKeys[TerritoryNameMap.normalize(alias)] { #expect(existing == code, "alias \(alias)") }
            #expect(Set(names.storefronts.values).contains(code), "alias \(alias) points to unknown code")
        }
    }

    @Test func unknownNameIsNil() throws {
        let map = try TerritoryNameMap.bundled()
        #expect(map.code(for: "Narnia") == nil)
        #expect(map.code(for: "") == nil)
        #expect(TerritoryNameMap(entries: ["Alpha Land": "ALP"]).code(for: "alpha  land") == "ALP")
    }

    @Test func everyCodeExistsInRecordedTerritoriesFixture() throws {
        let asc = try RepoFiles.ascTerritories()
        let names = try RepoFiles.territoryNames()
        let missing = Set(names.storefronts.values).subtracting(asc.keys)
        #expect(missing.isEmpty, "codes missing in fixture: \(missing.sorted())")
        #expect(asc.count == 175)
    }
}
