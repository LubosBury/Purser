import Foundation
import Testing
import Domain
import Catalog
import Policy
@testable import Planner
import PurserTestSupport

private let yearlyOwner = LocalizationOwner.subscription("s")    // live version 1: en-US, cs
private let lifetimeOwner = LocalizationOwner.iap("life")        // live version 1: en-US
private let freshOwner = LocalizationOwner.subscription("n")     // version 1 PREPARE_FOR_SUBMISSION: en-US, never approved
private let groupOwner = LocalizationOwner.group("group-1")      // live version 1: en-US

private let english = LocalizationText(name: "Fruit Yearly", description: "All fruit")
private let czech = LocalizationText(name: "Ovoce ročně", description: "Všechno ovoce")

private func catalog() -> SyntheticCatalog {
    var catalog = yearly()
    catalog.addIAP("life", base: "USA", manual: ["USA": d("49.99")])
    catalog.addSubscription("n", prices: ["USA": d("9.99")], state: .missingMetadata)
    catalog.addGroup()
    catalog.addTexts(yearlyOwner, live: ["en-US": english, "cs": czech])
    catalog.addTexts(lifetimeOwner, live: ["en-US": LocalizationText(name: "Fruit Lifetime", description: "Forever")])
    catalog.addTexts(freshOwner, live: [:], pending: ["en-US": LocalizationText(name: "Fruit New", description: "New fruit")],
                     pendingState: .prepareForSubmission)
    catalog.addTexts(groupOwner, live: ["en-US": LocalizationText(name: "Fruit Premium", customAppName: "Fruit")])
    return catalog
}

private func localeEdit(_ owner: LocalizationOwner, _ locale: String, name: String? = nil, description: String? = nil,
                        customAppName: String? = nil) -> LocalizationEdit {
    LocalizationEdit(owner: owner, locale: locale, name: name, description: description, customAppName: customAppName)
}

private func draft(_ edits: [LocalizationEdit], _ snapshot: CatalogSnapshot = catalog().snapshot()) throws -> PlanDraft {
    try plan(.localization(LocalizationPlanSpec(edits: edits)), snapshot)
}

private func isVersion(_ item: PlannedItem) -> Bool {
    if case .createMetadataVersion = item.payload { return true }
    return false
}

private func textPayload(_ item: PlannedItem) -> SetLocalization? {
    if case let .setLocalization(s) = item.payload { return s }
    return nil
}

/// Locales that get a text item in a new version when `edited` change: until a live trial shows that Apple copies the
/// Live texts (AppleConstants.newVersionCopiesLocalizations), every Live locale is carried over too.
private func expectedLocales(_ edited: Set<String>, live: Set<String>) -> [String] {
    (AppleConstants.newVersionCopiesLocalizations ? edited : edited.union(live)).sorted()
}

@Suite("Planner: new versions of approved products (L3)")
struct NewVersionPlannerTests {
    @Test func oneVersionItemPerOwnerAndEveryTextDependsOnIt() throws {
        let plan = try draft([localeEdit(yearlyOwner, "en-US", name: "Fruit Yearly Plus"), localeEdit(yearlyOwner, "de-DE", name: "Obst jährlich"),
                              localeEdit(lifetimeOwner, "en-US", description: "Every fruit, forever")])
        #expect(plan.blocks.isEmpty)
        let versions = plan.items.filter(isVersion)
        #expect(versions.map(\.cell).sorted { $0.storageKey < $1.storageKey }
                == [.metadataVersion(owner: lifetimeOwner), .metadataVersion(owner: yearlyOwner)])
        for version in versions {
            guard case let .createMetadataVersion(owner) = version.payload else { continue }
            let texts = plan.items.filter { textPayload($0)?.owner == owner }
            #expect(!texts.isEmpty)
            #expect(texts.allSatisfy { $0.dependsOn == [version.seq] && $0.seq > version.seq })
        }
        #expect(plan.items.filter { textPayload($0)?.owner == yearlyOwner }.compactMap { textPayload($0)?.locale }.sorted()
                == expectedLocales(["en-US", "de-DE"], live: ["en-US", "cs"]))
        #expect(plan.items.filter { textPayload($0)?.owner == lifetimeOwner }.compactMap { textPayload($0)?.locale }.sorted()
                == expectedLocales(["en-US"], live: ["en-US"]))
    }

    @Test func theVersionItemOpensTheNextNumberInPrepareForSubmission() throws {
        let plan = try draft([localeEdit(yearlyOwner, "en-US", name: "Fruit Yearly Plus")])
        let version = try #require(plan.items.first(where: isVersion))
        #expect(version.payload == .createMetadataVersion(owner: yearlyOwner))
        #expect(version.cell == .metadataVersion(owner: yearlyOwner))
        #expect(version.op == .post)
        #expect(version.before == .metadataVersion(nil))
        #expect(version.target == .metadataVersion(MetadataVersion(ascId: "", owner: yearlyOwner, number: 2, state: .prepareForSubmission)))
        #expect(version.rules == ["N5"])
        #expect(version.naturalKey == "V+|S|s")
        #expect(version.dependsOn.isEmpty)
    }

    @Test func textItemsCarryNoIdsAndStartFromTheSnapshot() throws {
        let snapshot = catalog().snapshot()
        let plan = try draft([localeEdit(yearlyOwner, "en-US", name: "Fruit Yearly Plus"),
                              localeEdit(yearlyOwner, "de-DE", name: "Obst jährlich", description: "Alles Obst")], snapshot)
        let liveEnglish = try #require(snapshot.localization(yearlyOwner, locale: "en-US", versionId: "ver-s-1"))
        let englishItem = try #require(plan.items.first { textPayload($0)?.locale == "en-US" })
        let s = try #require(textPayload(englishItem))
        #expect(s.localizationId == nil)
        #expect(s.versionId == nil)
        #expect(s.text == LocalizationText(name: "Fruit Yearly Plus", description: "All fruit"))
        #expect(englishItem.before == snapshot.cellState(englishItem.cell, on: today))
        let placeholder = MetadataVersion(ascId: "", owner: yearlyOwner, number: 2, state: .prepareForSubmission)
        #expect(englishItem.target == .localization(live: liveEnglish,
                                                    pending: LocalizationRow(ascId: "", owner: yearlyOwner, versionId: "", locale: "en-US", text: s.text),
                                                    pendingVersion: placeholder))
        #expect(englishItem.rules == ["N1", "N2", "N3", "N4"])
        let german = try #require(plan.items.first { textPayload($0)?.locale == "de-DE" })
        #expect(textPayload(german)?.text == LocalizationText(name: "Obst jährlich", description: "Alles Obst"))
        #expect(german.before == .localization(live: nil, pending: nil, pendingVersion: nil))
    }

    @Test func liveTextsAreCarriedOverOnlyUntilTheSpikeConfirmsCopying() throws {
        let snapshot = catalog().snapshot()
        let live = try #require(snapshot.liveVersion(of: yearlyOwner))
        let context = PlanningContext(snapshot: snapshot, config: SyntheticCatalog.config(), today: today)
        var unconfirmed = PlanBuilder(context: context, origin: .localization)
        unconfirmed.addTextsInNewVersion(owner: yearlyOwner, live: live, edits: [localeEdit(yearlyOwner, "en-US", name: "Fruit Yearly Plus")],
                                         copiesLocalizations: false)
        let carried = try #require(unconfirmed.sink.items.first { textPayload($0)?.locale == "cs" })
        #expect(textPayload(carried)?.text == czech)
        #expect(carried.dependsOn == [1])
        #expect(!OrphanVersions.changesText(carried))
        var confirmed = PlanBuilder(context: context, origin: .localization)
        confirmed.addTextsInNewVersion(owner: yearlyOwner, live: live, edits: [localeEdit(yearlyOwner, "en-US", name: "Fruit Yearly Plus")],
                                       copiesLocalizations: true)
        #expect(confirmed.sink.items.compactMap { textPayload($0)?.locale } == ["en-US"])
    }

    @Test func anOwnerWithAVersionInPreparationGetsNoVersionItem() throws {
        let plan = try draft([localeEdit(freshOwner, "en-US", name: "Fruit New Plus")])
        #expect(plan.items.count == 1)
        #expect(!plan.items.contains(where: isVersion))
        #expect(plan.verdicts("N5").isEmpty)
    }

    @Test func identicalTextOpensNoVersion() throws {
        let plan = try draft([localeEdit(yearlyOwner, "en-US", name: "Fruit Yearly", description: "All fruit"), localeEdit(yearlyOwner, "cs")])
        #expect(plan.items.isEmpty)
        #expect(plan.excluded.isEmpty)
        #expect(plan.verdicts.isEmpty)
    }

    @Test func aVersionIsNeverCreatedWhenEveryChangedTextIsBlocked() throws {
        // fr-FR is new and has no name: N4 blocks it, and carried-over Live texts alone change nothing.
        let plan = try draft([localeEdit(yearlyOwner, "fr-FR", description: "Un an de fruits")])
        #expect(plan.items.isEmpty)
        #expect(plan.excluded.contains(.metadataVersion(owner: yearlyOwner)))
        #expect(plan.excluded.contains(.localization(owner: yearlyOwner, locale: "fr-FR")))
        #expect(!plan.verdicts("N4").isEmpty)
    }

    @Test func aGroupInANewVersionTakesOnlyTheCustomAppName() throws {
        let plan = try draft([localeEdit(groupOwner, "en-US", customAppName: "Fruit+")])
        #expect(plan.items.map(\.cell) == [.metadataVersion(owner: groupOwner), .localization(owner: groupOwner, locale: "en-US")])
        #expect(textPayload(plan.items[1])?.text == LocalizationText(name: "Fruit Premium", customAppName: "Fruit+"))
        let wrong = try draft([localeEdit(groupOwner, "cs", name: "Ovoce", description: "No")])
        #expect(wrong.items.isEmpty)
        #expect(wrong.verdicts("PLAN").map(\.severity) == [.block(.cell)])
        #expect(wrong.verdicts("PLAN").first?.message == "A subscription group has no description; put the text into the custom app name.")
    }

    @Test func aNewVersionNeedsC1() throws {
        let plan = try draft([localeEdit(yearlyOwner, "en-US", name: "Fruit Yearly Plus"), localeEdit(lifetimeOwner, "en-US", name: "Fruit Lifetime Plus")])
        let n5 = plan.verdicts("N5")
        #expect(n5.count == 2)
        #expect(n5.allSatisfy { $0.severity == .confirm(.c1) && $0.riskClass == nil })
        #expect(Set(n5.compactMap(\.cell)) == [.metadataVersion(owner: yearlyOwner), .metadataVersion(owner: lifetimeOwner)])
        #expect(plan.confirmationLevel == .c1)
    }

    @Test func theEstimateCountsTheVersionWriteAndItsReads() throws {
        let plan = try draft([localeEdit(yearlyOwner, "en-US", name: "Fruit Yearly Plus"), localeEdit(lifetimeOwner, "en-US", name: "Fruit Lifetime Plus")])
        #expect(plan.estimate.requests == RequestEstimator.requests(items: plan.items))
        // Per version: its POST plus one preflight and one verify page of its own cell kind ("V"); the texts' reads stay.
        let withoutVersions = RequestEstimator.requests(items: plan.items.filter { !isVersion($0) })
        #expect(RequestEstimator.requests(items: plan.items) - withoutVersions == 2 * 3)
    }

    @Test func newVersionTextKeepsWhatTheEditLeavesEmpty() {
        let current = LocalizationText(name: "Yearly", description: "One year of fruit")
        #expect(PlanBuilder.newVersionText(localeEdit(yearlyOwner, "en-US", name: " Yearly Plus ", description: ""), current: current, kind: .subscription)
                == LocalizationText(name: "Yearly Plus", description: "One year of fruit"))
        #expect(PlanBuilder.newVersionText(localeEdit(yearlyOwner, "en-US", name: "  ", description: "One year"), current: current, kind: .subscription)
                == LocalizationText(name: "Yearly", description: "One year"))
        #expect(PlanBuilder.newVersionText(localeEdit(yearlyOwner, "en-US", name: "Yearly"), current: current, kind: .subscription) == nil)
        #expect(PlanBuilder.newVersionText(localeEdit(yearlyOwner, "de-DE"), current: nil, kind: .subscription) == nil)
        #expect(PlanBuilder.newVersionText(localeEdit(yearlyOwner, "fr-FR", description: "Un an"), current: nil, kind: .subscription)
                == LocalizationText(name: "", description: "Un an"))
        #expect(PlanBuilder.newVersionText(localeEdit(groupOwner, "en-US", customAppName: "Fruit Jar Pro"),
                                           current: LocalizationText(name: "Premium", customAppName: "Fruit Jar"), kind: .group)
                == LocalizationText(name: "Premium", customAppName: "Fruit Jar Pro"))
    }
}
