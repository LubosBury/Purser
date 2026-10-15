import Foundation
import Testing
import Domain
import Store
import Catalog
import Policy
@testable import Planner
import PurserTestSupport

private let s = LocalizationOwner.subscription("s")
private let t = LocalizationOwner.subscription("t")
private let life = LocalizationOwner.iap("life")
private let group = LocalizationOwner.group("group-1")

/// s: live v1 and draft v2 (en-US, cs); t: only live v1; life: draft v1 (en-US); group-1: live v1 and draft v2 (en-US);
/// the IAP "bare" has no version.
private func texts() -> SyntheticCatalog {
    var catalog = yearly()
    catalog.addSubscription("t", prices: ["USA": d("9.99")])
    catalog.addIAP("life", base: "USA", manual: ["USA": d("49.99")])
    catalog.addIAP("bare", base: "USA", manual: ["USA": d("19.99")])
    catalog.addGroup()
    let yearlyText = LocalizationText(name: "Fruit Yearly", description: "All fruit")
    catalog.addTexts(s, live: ["en-US": yearlyText],
                     pending: ["en-US": yearlyText, "cs": LocalizationText(name: "Ovoce ročně", description: "Všechno ovoce")],
                     pendingState: .prepareForSubmission)
    catalog.addTexts(t, live: ["en-US": LocalizationText(name: "Fruit Monthly", description: "Fruit")])
    catalog.addTexts(life, live: [:], pending: ["en-US": LocalizationText(name: "Fruit Lifetime", description: "Forever")],
                     pendingState: .prepareForSubmission)
    let premium = LocalizationText(name: "Fruit Premium", customAppName: "Fruit")
    catalog.addTexts(group, live: ["en-US": premium], pending: ["en-US": premium], pendingState: .prepareForSubmission)
    return catalog
}

private func textPlan(_ edits: [LocalizationEdit], _ snapshot: CatalogSnapshot = texts().snapshot()) throws -> PlanDraft {
    try plan(.localization(LocalizationPlanSpec(edits: edits)), snapshot)
}

private func text(_ item: PlannedItem) -> SetLocalization? {
    if case let .setLocalization(value) = item.payload { return value }
    return nil
}

@Suite struct LocalizationPlannerTests {
    @Test func anEmptyFieldKeepsTheCurrentTextAndAKnownLocaleIsAPatch() throws {
        let snapshot = texts().snapshot()
        let draft = try textPlan([LocalizationEdit(owner: s, locale: "en-US", name: "  ", description: "Fresh fruit")], snapshot)
        #expect(draft.ops == [.setText])
        let item = draft.items[0]
        let write = try #require(text(item))
        #expect(write.text == LocalizationText(name: "Fruit Yearly", description: "Fresh fruit"))
        #expect(write.localizationId == "loc-s-2-en-US")
        #expect(write.versionId == nil)
        #expect(item.cell == .localization(owner: s, locale: "en-US"))
        #expect(item.before == snapshot.cellState(item.cell, on: today))
        #expect(item.rules == ["N1", "N2", "N3", "N4"])
        guard case let .localization(live, pending, version) = item.target else { Issue.record("target"); return }
        #expect(live?.ascId == "loc-s-1-en-US")
        #expect(pending?.ascId == "loc-s-2-en-US")
        #expect(pending?.text.description == "Fresh fruit")
        #expect(version?.ascId == "ver-s-2")
        #expect(draft.blocks.isEmpty)
    }

    @Test func aNewLocaleIsAPostIntoTheVersionInPreparation() throws {
        let draft = try textPlan([LocalizationEdit(owner: s, locale: "de-DE", name: "Obst", description: "Alles Obst")])
        let write = try #require(draft.items.first.flatMap(text))
        #expect(write.localizationId == nil)
        #expect(write.versionId == "ver-s-2")
        guard case let .localization(_, pending, _) = draft.items[0].target else { Issue.record("target"); return }
        #expect(pending?.ascId == "")
        #expect(pending?.text == LocalizationText(name: "Obst", description: "Alles Obst"))
    }

    @Test func anIdenticalOrEmptyRowGivesNoItem() throws {
        let draft = try textPlan([
            LocalizationEdit(owner: s, locale: "cs", name: "Ovoce ročně", description: "Všechno ovoce"),
            LocalizationEdit(owner: s, locale: "en-US"),
            LocalizationEdit(owner: life, locale: "en-US", name: "Fruit Lifetime"),
        ])
        #expect(draft.items.isEmpty)
        #expect(draft.verdicts.isEmpty)
    }

    @Test func aGroupRowUsesTheCustomAppName() throws {
        let draft = try textPlan([LocalizationEdit(owner: group, locale: "en-US", customAppName: "Fruit+")])
        let write = try #require(draft.items.first.flatMap(text))
        #expect(write.text == LocalizationText(name: "Fruit Premium", description: nil, customAppName: "Fruit+"))
        #expect(write.localizationId == "loc-group-1-2-en-US")
        let wrong = try textPlan([LocalizationEdit(owner: group, locale: "en-US", description: "No"),
                                  LocalizationEdit(owner: s, locale: "en-US", customAppName: "No")])
        #expect(wrong.items.isEmpty)
        #expect(wrong.verdicts("PLAN").map(\.severity) == [.block(.cell), .block(.cell)])
    }

    @Test func anOwnerWithOnlyALiveVersionGetsANewVersion() throws {
        let draft = try textPlan([LocalizationEdit(owner: t, locale: "en-US", name: "Fruit Monthly Plus"),
                                  LocalizationEdit(owner: t, locale: "cs")])
        // L3: the version item first, the changed text depends on it; the row without text gives nothing (t has only en-US).
        #expect(draft.items.map(\.cell) == [.metadataVersion(owner: t), .localization(owner: t, locale: "en-US")])
        #expect(draft.items[1].dependsOn == [draft.items[0].seq])
        let n5 = draft.verdicts("N5")
        #expect(n5.map(\.severity) == [.confirm(.c1)])
        #expect(n5.first?.cell == .metadataVersion(owner: t))
        #expect(draft.excluded.isEmpty)
    }

    @Test func aForeignFieldBlocksItsCellEvenForAnOwnerWithOnlyALiveVersion() throws {
        var catalog = texts()
        let liveGroup = LocalizationOwner.group("group-live")
        catalog.addGroup("group-live", name: "Live group")
        catalog.addTexts(liveGroup, live: ["en-US": LocalizationText(name: "Live Premium", customAppName: "Live")])
        let draft = try textPlan([LocalizationEdit(owner: liveGroup, locale: "en-US", description: "No"),
                                  LocalizationEdit(owner: t, locale: "en-US", customAppName: "No")], catalog.snapshot())
        #expect(draft.items.isEmpty)
        #expect(draft.verdicts("N5").isEmpty)
        #expect(draft.verdicts("PLAN").map(\.severity) == [.block(.cell), .block(.cell)])
        #expect(Set(draft.verdicts("PLAN").compactMap(\.cell))
                == [.localization(owner: liveGroup, locale: "en-US"), .localization(owner: t, locale: "en-US")])
        #expect(draft.excluded.count == 2)
    }

    @Test func aPaddedValueIsTrimmedInThePlannedText() throws {
        let draft = try textPlan([LocalizationEdit(owner: s, locale: "en-US", name: "  Yearly  ", description: " \n Fresh fruit\t")])
        let write = try #require(draft.items.first.flatMap(text))
        #expect(write.text == LocalizationText(name: "Yearly", description: "Fresh fruit"))
    }

    @Test func anUnchangedRowOfALiveOnlyOwnerIsNotBlocked() throws {
        let draft = try textPlan([LocalizationEdit(owner: t, locale: "en-US", name: "Fruit Monthly", description: "Fruit")])
        #expect(draft.items.isEmpty)
        #expect(draft.verdicts.isEmpty)
    }

    @Test func anOwnerWithoutVersionsOrOutsideTheCatalogBlocksThePlan() throws {
        let bare = try textPlan([LocalizationEdit(owner: .iap("bare"), locale: "en-US", name: "Bare")])
        #expect(bare.items.isEmpty)
        #expect(bare.verdicts("PLAN").map(\.severity) == [.block(.plan)])
        let unknown = try textPlan([LocalizationEdit(owner: .subscription("nope"), locale: "en-US", name: "Nope")])
        #expect(unknown.verdicts("PLAN").map(\.severity) == [.block(.plan)])
    }

    @Test func aRowTwiceBlocksItsCellOnly() throws {
        let draft = try textPlan([LocalizationEdit(owner: s, locale: "en-US", name: "One"),
                                  LocalizationEdit(owner: s, locale: "en-US", name: "Two"),
                                  LocalizationEdit(owner: s, locale: "de-DE", name: "Obst")])
        #expect(draft.items.compactMap(text).map(\.locale) == ["de-DE"])
        #expect(draft.verdicts("PLAN").map(\.cell) == [.localization(owner: s, locale: "en-US")])
        #expect(draft.verdicts("PLAN").first?.message.contains("more than once") == true)
    }

    @Test func theSpecRoundTripsAndHasItsOrigin() throws {
        let spec = PlanSpec.localization(LocalizationPlanSpec(edits: [LocalizationEdit(owner: group, locale: "cs", name: "Ovoce", customAppName: "O")]))
        #expect(spec.origin == .localization)
        #expect(try JSONCoding.decode(PlanSpec.self, from: JSONCoding.string(spec)) == spec)
    }

    @Test func diffRowsShowTheLocaleAndBothTexts() throws {
        let snapshot = texts().snapshot()
        let spec = PlanSpec.localization(LocalizationPlanSpec(edits: [
            LocalizationEdit(owner: s, locale: "en-US", description: "Fresh fruit"),
            LocalizationEdit(owner: s, locale: "de-DE", name: "Obst", description: "Alles Obst"),
        ]))
        let draft = try plan(spec, snapshot)
        let rows = PlanDiff.rows(items: draft.items, verdicts: draft.verdicts, spec: spec, snapshot: snapshot,
                                 config: SyntheticCatalog.config(), today: today)
        #expect(rows.map(\.locale) == ["de-DE", "en-US"])
        #expect(rows.allSatisfy { $0.territory == nil && $0.currency == nil })
        #expect(rows[0].before == "—")
        #expect(rows[0].after == "de-DE: Obst — Alles Obst")
        #expect(rows[0].beforeText == nil)
        #expect(PlanDiff.changedFields(rows[0].beforeText, rows[0].afterText) == [.name, .description])
        #expect(rows[1].before == "en-US: Fruit Yearly — All fruit")
        #expect(rows[1].after == "en-US: Fruit Yearly — Fresh fruit")
        #expect(PlanDiff.changedFields(rows[1].beforeText, rows[1].afterText) == [.description])
        #expect(LocalizationField.customAppName.label == "Custom app name")
    }
}
