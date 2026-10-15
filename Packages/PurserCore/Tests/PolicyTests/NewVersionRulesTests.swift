import Foundation
import Testing
import Domain
import Catalog
@testable import Policy
import PurserTestSupport

private let owner = LocalizationOwner.subscription("s")      // basicCatalog(): "Synthetic s", APPROVED

/// "s" with a live version 1 (en-US) and, with `pendingState`, a version 2 in that state.
private func snapshot(pendingState: MetadataVersionState? = nil) -> CatalogSnapshot {
    var catalog = basicCatalog()
    let english = LocalizationText(name: "Fruit Yearly", description: "All fruit")
    catalog.addTexts(owner, live: ["en-US": english], pending: pendingState == nil ? [:] : ["en-US": english], pendingState: pendingState)
    return catalog.snapshot()
}

private func versionItem(number: Int = 2) -> PlannedItem {
    PlannedItem(seq: 1, cell: .metadataVersion(owner: owner), payload: .createMetadataVersion(owner: owner), before: .metadataVersion(nil),
                target: .metadataVersion(MetadataVersion(ascId: "", owner: owner, number: number, state: .prepareForSubmission)),
                rules: ["N5"])
}

/// A text of "s" for the new version of `versionItem()`, as the Planner writes it: no ids, `before` from `snapshot`.
private func textInNewVersion(_ snapshot: CatalogSnapshot, locale: String, text: LocalizationText) -> PlannedItem {
    let cell = CellKey.localization(owner: owner, locale: locale)
    return PlannedItem(seq: 2, cell: cell, payload: .setLocalization(SetLocalization(owner: owner, locale: locale, text: text,
                                                                                     localizationId: nil, versionId: nil)),
                       before: snapshot.cellState(cell, on: today), target: snapshot.cellState(cell, on: today), dependsOn: [1],
                       rules: ["N1", "N2", "N3", "N4"])
}

@Suite("Rules for new versions (L3)")
struct NewVersionRulesTests {
    @Test func aLiveTextCarriedOverUnchangedIsNotJudgedByN2ToN4() {
        // App Store Connect accepted this Live text, though a locale missing from Purser's list and a 31-character name
        // would fail N2 and N3 as new text.
        let accepted = LocalizationText(name: String(repeating: "a", count: 31), description: "All fruit")
        var catalog = basicCatalog()
        catalog.addTexts(owner, live: ["en-US": LocalizationText(name: "Fruit Yearly", description: "All fruit"), "xx-YY": accepted])
        let snapshot = catalog.snapshot()
        let rules: [any PlanRule] = [N2LocaleRule(), N3TextLengthRule(), N4NewLocaleNameRule()]

        let carried = textInNewVersion(snapshot, locale: "xx-YY", text: accepted)
        #expect(rules.flatMap { $0.evaluate(context(snapshot, [versionItem(), carried], origin: .localization)) }.isEmpty)

        let changed = textInNewVersion(snapshot, locale: "xx-YY", text: LocalizationText(name: accepted.name, description: "Fruit for all"))
        #expect(rules.flatMap { $0.evaluate(context(snapshot, [versionItem(), changed], origin: .localization)) }.map(\.rule).sorted()
                == ["N2", "N3"])
    }

    @Test func n5AsksForC1AndSaysWhatTheVersionMeans() throws {
        let verdicts = N5NewVersionRule().evaluate(context(snapshot(), [versionItem()], origin: .localization))
        #expect(verdicts.count == 1)
        let verdict = try #require(verdicts.first)
        #expect(verdict.rule == "N5")
        #expect(verdict.severity == .confirm(.c1))
        #expect(verdict.cell == .metadataVersion(owner: owner))
        #expect(verdict.riskClass == nil)
        #expect(verdict.message.contains("Synthetic s"))
        #expect(verdict.message.contains("cannot be deleted through the App Store Connect API"))
        #expect(verdict.message.contains("only after you submit it in App Store Connect and Apple approves it"))
    }

    @Test func n5IgnoresEveryOtherItem() {
        let catalog = snapshot()
        let text = ItemFactory.text(1, catalog, owner: owner, locale: "en-US", text: LocalizationText(name: "Fruit Yearly Plus"))
        #expect(N5NewVersionRule().evaluate(context(catalog, [text], origin: .localization)).isEmpty)
    }

    @Test func n1BlocksANewVersionWhileAnotherIsInReview() {
        let verdicts = N1VersionInReviewRule().evaluate(context(snapshot(pendingState: .waitingForReview), [versionItem()], origin: .localization))
        #expect(verdicts.map(\.severity) == [.block(.cell)])
        #expect(verdicts.first?.cell == .metadataVersion(owner: owner))
        #expect(verdicts.first?.message.contains("WAITING_FOR_REVIEW") == true)
    }

    @Test func n1LetsANewVersionThroughWithoutAVersionInReview() {
        #expect(N1VersionInReviewRule().evaluate(context(snapshot(), [versionItem()], origin: .localization)).isEmpty)
    }

    @Test func n5IsRegistered() {
        #expect(PolicyEngine.defaultPlanRules.contains { $0 is N5NewVersionRule })
    }
}
