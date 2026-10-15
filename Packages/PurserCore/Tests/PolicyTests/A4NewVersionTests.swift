import Foundation
import Testing
import Domain
import Catalog
@testable import Policy
import PurserTestSupport

private let owner = LocalizationOwner.subscription("s")
private let english = LocalizationText(name: "Fruit Yearly", description: "All fruit")

/// "s" with a live version 1 (en-US); with `copy` also version 2 in preparation that holds a copy of the live en-US.
private func snapshot(live: LocalizationText = english, copy: Bool = false) -> CatalogSnapshot {
    var catalog = basicCatalog()
    catalog.addTexts(owner, live: ["en-US": live], pending: copy ? ["en-US": live] : [:], pendingState: copy ? .prepareForSubmission : nil)
    return catalog.snapshot()
}

/// "s" with a live version 1 (en-US) and version 2 in `state` whose en-US is `pending`.
private func inPreparation(_ state: MetadataVersionState, pending: LocalizationText = english) -> CatalogSnapshot {
    var catalog = basicCatalog()
    catalog.addTexts(owner, live: ["en-US": english], pending: ["en-US": pending], pendingState: state)
    return catalog.snapshot()
}

/// "s" after version 2 (planned into while in preparation) was approved: version 3 in preparation holds a copy of its en-US.
private func approvedAndCopied() -> CatalogSnapshot {
    var catalog = basicCatalog()
    let versions = [MetadataVersionState.approved, .approved, .prepareForSubmission].enumerated().map { index, state in
        MetadataVersion(ascId: "ver-s-\(index + 1)", owner: owner, number: index + 1, state: state)
    }
    catalog.metadata[owner] = OwnerMetadata(owner: owner, versions: versions, localizations: versions.map {
        LocalizationRow(ascId: "loc-s-\($0.number)-en-US", owner: owner, versionId: $0.ascId, locale: "en-US", text: english)
    })
    return catalog.snapshot()
}

/// en-US of "s" as the Planner put it into a plan that creates a new version (no ids).
private func plannedText(localizationId: String?) -> PlannedItem {
    let cell = CellKey.localization(owner: owner, locale: "en-US")
    return PlannedItem(seq: 2, cell: cell,
                       payload: .setLocalization(SetLocalization(owner: owner, locale: "en-US", text: LocalizationText(name: "Fruit Yearly Plus"),
                                                                 localizationId: localizationId, versionId: nil)),
                       before: snapshot().cellState(cell, on: today), target: snapshot().cellState(cell, on: today), dependsOn: [1])
}

@Suite("A4 after a new version (L3)")
struct A4NewVersionTests {
    @Test func aTextInTheVersionThePlanCreatedStillStartsFromTheSnapshot() {
        let item = plannedText(localizationId: nil)
        let afterVersion = snapshot(copy: true)
        #expect(item.before != afterVersion.cellState(item.cell, on: today))
        #expect(A4FreshBaseRule().evaluate(context(afterVersion, [item], origin: .localization)).isEmpty)
    }

    @Test func aTextWithIdsStillStartsFromTheSnapshotWhenItsVersionIsReadyForReview() {
        let item = ItemFactory.text(1, inPreparation(.prepareForSubmission), owner: owner, locale: "en-US",
                                    text: LocalizationText(name: "Fruit Yearly Plus"))
        #expect(item.newText?.localizationId == "loc-s-2-en-US")
        let ready = inPreparation(.readyForReview)
        #expect(item.before != ready.cellState(item.cell, on: today))
        #expect(A4FreshBaseRule().evaluate(context(ready, [item], origin: .localization)).isEmpty)
    }

    @Test func aTextWithIdsBlocksWhenItsVersionWentIntoReview() {
        let item = ItemFactory.text(1, inPreparation(.prepareForSubmission), owner: owner, locale: "en-US",
                                    text: LocalizationText(name: "Fruit Yearly Plus"))
        #expect(A4FreshBaseRule().evaluate(context(inPreparation(.waitingForReview), [item], origin: .localization)).map(\.rule) == ["A4"])
    }

    @Test func aTextWithIdsBlocksWhenItsVersionWasApprovedAndANewOneCopiedItsTexts() {
        let patch = ItemFactory.text(1, inPreparation(.prepareForSubmission), owner: owner, locale: "en-US",
                                     text: LocalizationText(name: "Fruit Yearly Plus"))
        let post = ItemFactory.text(1, inPreparation(.prepareForSubmission), owner: owner, locale: "cs", text: LocalizationText(name: "Ovoce"))
        #expect(patch.newText?.localizationId == "loc-s-2-en-US")
        #expect(post.newText?.versionId == "ver-s-2")
        for item in [patch, post] {
            #expect(A4FreshBaseRule().evaluate(context(approvedAndCopied(), [item], origin: .localization)).map(\.rule) == ["A4"])
        }
    }

    @Test func aTextWithIdsBlocksWhenItsTextChangedInAppStoreConnect() {
        let item = ItemFactory.text(1, inPreparation(.prepareForSubmission), owner: owner, locale: "en-US",
                                    text: LocalizationText(name: "Fruit Yearly Plus"))
        let changed = inPreparation(.prepareForSubmission, pending: LocalizationText(name: "Changed in App Store Connect", description: "All fruit"))
        #expect(A4FreshBaseRule().evaluate(context(changed, [item], origin: .localization)).map(\.rule) == ["A4"])
    }

    @Test func aLiveTextChangedInAppStoreConnectStillBlocks() {
        let item = plannedText(localizationId: nil)
        let changed = snapshot(live: LocalizationText(name: "Changed in App Store Connect", description: "All fruit"), copy: true)
        #expect(A4FreshBaseRule().evaluate(context(changed, [item], origin: .localization)).map(\.rule) == ["A4"])
    }
}
