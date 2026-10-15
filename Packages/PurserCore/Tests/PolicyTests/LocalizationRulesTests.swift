import Foundation
import Testing
import Domain
import Catalog
@testable import Policy
import PurserTestSupport

private let s = LocalizationOwner.subscription("s")
private let g = LocalizationOwner.group("group-1")

private func snapshot(draftState: MetadataVersionState = .prepareForSubmission) -> CatalogSnapshot {
    var catalog = basicCatalog()
    catalog.addGroup()
    let english = LocalizationText(name: "Fruit Yearly", description: "All fruit")
    catalog.addTexts(s, live: ["en-US": english], pending: ["en-US": english], pendingState: draftState)
    catalog.addTexts(g, live: [:], pending: ["en-US": LocalizationText(name: "Fruit Premium", customAppName: "Fruit")], pendingState: .prepareForSubmission)
    return catalog.snapshot()
}

@Suite struct LocalizationRulesTests {
    @Test func n1BlocksAVersionInReview() {
        let open = snapshot()
        let item = ItemFactory.text(1, open, owner: s, locale: "en-US", text: LocalizationText(name: "Fruit Yearly Plus"))
        #expect(N1VersionInReviewRule().evaluate(context(open, [item])).isEmpty)
        let review = snapshot(draftState: .waitingForReview)
        let verdicts = N1VersionInReviewRule().evaluate(context(review, [item]))
        #expect(verdicts.map(\.severity) == [.block(.cell)])
        #expect(verdicts.first?.cell == item.cell)
    }

    @Test func n2BlocksALocaleASCDoesNotKnow() {
        let catalog = snapshot()
        let known = ItemFactory.text(1, catalog, owner: s, locale: "cs", text: LocalizationText(name: "Ovoce"))
        #expect(N2LocaleRule().evaluate(context(catalog, [known])).isEmpty)
        let unknown = ItemFactory.text(1, catalog, owner: s, locale: "en-XX", text: LocalizationText(name: "Fruit"))
        #expect(N2LocaleRule().evaluate(context(catalog, [unknown])).map(\.severity) == [.block(.cell)])
    }

    @Test func n3BlocksTextsOutsideApplesLimitsButNotForGroups() {
        let catalog = snapshot()
        let fits = ItemFactory.text(1, catalog, owner: s, locale: "en-US",
                                    text: LocalizationText(name: String(repeating: "a", count: 30), description: String(repeating: "b", count: 45)))
        #expect(N3TextLengthRule().evaluate(context(catalog, [fits])).isEmpty)
        let long = ItemFactory.text(1, catalog, owner: s, locale: "en-US",
                                    text: LocalizationText(name: String(repeating: "a", count: 31), description: String(repeating: "b", count: 46)))
        let verdicts = N3TextLengthRule().evaluate(context(catalog, [long]))
        #expect(verdicts.map(\.severity) == [.block(.cell)])
        #expect(verdicts.first?.message.contains("31") == true)
        #expect(verdicts.first?.message.contains("46") == true)
        let group = ItemFactory.text(1, catalog, owner: g, locale: "en-US", text: LocalizationText(name: String(repeating: "a", count: 80), customAppName: "Fruit"))
        #expect(N3TextLengthRule().evaluate(context(catalog, [group])).isEmpty)
    }

    @Test func n3CountsOneCharacterInTheSingular() {
        let catalog = snapshot()
        let short = ItemFactory.text(1, catalog, owner: s, locale: "en-US", text: LocalizationText(name: "F", description: "All fruit"))
        #expect(N3TextLengthRule().evaluate(context(catalog, [short])).map(\.message) == ["en-US: the name has 1 character, Apple allows 2 to 30."])
        let long = ItemFactory.text(1, catalog, owner: s, locale: "en-US",
                                    text: LocalizationText(name: String(repeating: "a", count: 31), description: String(repeating: "b", count: 46)))
        #expect(N3TextLengthRule().evaluate(context(catalog, [long])).map(\.message)
                == ["en-US: the name has 31 characters, Apple allows 2 to 30; the description has 46 characters, Apple allows at most 45."])
    }

    @Test func n4BlocksANewLocaleWithoutAName() {
        let catalog = snapshot()
        let named = ItemFactory.text(1, catalog, owner: s, locale: "cs", text: LocalizationText(name: "Ovoce"))
        #expect(N4NewLocaleNameRule().evaluate(context(catalog, [named])).isEmpty)
        let nameless = ItemFactory.text(1, catalog, owner: s, locale: "cs", text: LocalizationText(name: " ", description: "Všechno ovoce"))
        #expect(N4NewLocaleNameRule().evaluate(context(catalog, [nameless])).map(\.severity) == [.block(.cell)])
        let existing = ItemFactory.text(1, catalog, owner: s, locale: "en-US", text: LocalizationText(name: ""))
        #expect(N4NewLocaleNameRule().evaluate(context(catalog, [existing])).isEmpty)
    }

    @Test func theRulesAreRegistered() {
        let ids = Set(PolicyEngine.defaultPlanRules.map(\.id))
        #expect(ids.isSuperset(of: ["N1", "N2", "N3", "N4"]))
    }
}
