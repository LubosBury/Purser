import Foundation
import Testing
import Domain
@testable import Catalog

@Suite struct PurserItemsLocalizationTests {
    @Test func aTextRowIsExplainedByTheNaturalKeyOfItsSetText() {
        let owner = LocalizationOwner.subscription("sub-1")
        let row = LocalizationRow(ascId: "loc-new", owner: owner, versionId: "ver-1", locale: "cs",
                                  text: LocalizationText(name: "Ovoce", description: "Všechno ovoce"))
        let key = NaturalKey.of(.setLocalization(SetLocalization(owner: owner, locale: "cs", text: row.text,
                                                                 localizationId: nil, versionId: "ver-1")))
        #expect(PurserItems.appearanceKeys(.localization(row)) == [key])
    }
}
