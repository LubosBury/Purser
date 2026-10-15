import Foundation
import Testing
import Domain
import Store
@testable import Planner
import PurserTestSupport

private let yearlyOwner = LocalizationOwner.subscription("6500000001")
private let lifetimeOwner = LocalizationOwner.iap("6600000001")

private func storedPlan(_ state: PlanState) -> StoredPlan {
    StoredPlan(id: "p1", origin: .localization, specJSON: "{}", importJSON: nil, binding: PlanBinding(config: SyntheticCatalog.config()),
               baseSyncId: 1, state: state, pauseReason: nil, endReason: nil, planHash: "h", verdictHash: "v", verdicts: [], excluded: [],
               productStates: [:], reason: nil, confirmationLevel: .c1, appBuild: "test", estimateRequests: 3, estimateMinutes: 1,
               replanOf: nil, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), heartbeatAt: nil)
}

private func versionItem(_ owner: LocalizationOwner, seq: Int, number: Int, state: ItemState, ascId: String?) -> StoredItem {
    let item = PlannedItem(seq: seq, cell: .metadataVersion(owner: owner), payload: .createMetadataVersion(owner: owner),
                           before: .metadataVersion(nil),
                           target: .metadataVersion(MetadataVersion(ascId: "", owner: owner, number: number, state: .prepareForSubmission)),
                           rules: ["N5"])
    return StoredItem(planId: "p1", item: item, state: state, attempts: 1, ascId: ascId, errorJSON: nil, verifiedAt: nil,
                      effectiveAt: nil, supersededBy: nil)
}

private func textItem(_ owner: LocalizationOwner, seq: Int, locale: String, state: ItemState) -> StoredItem {
    let item = PlannedItem(seq: seq, cell: .localization(owner: owner, locale: locale),
                           payload: .setLocalization(SetLocalization(owner: owner, locale: locale, text: LocalizationText(name: "Yearly"),
                                                                     localizationId: nil, versionId: nil)),
                           before: .localization(live: nil, pending: nil, pendingVersion: nil),
                           target: .localization(live: nil, pending: nil, pendingVersion: nil), dependsOn: [1])
    return StoredItem(planId: "p1", item: item, state: state, attempts: 1, ascId: nil, errorJSON: nil, verifiedAt: nil,
                      effectiveAt: nil, supersededBy: nil)
}

private func ownerMetadata(_ owner: LocalizationOwner, _ versions: [(String, Int, MetadataVersionState)],
                           texts: [(versionId: String, locale: String)] = []) -> OwnerMetadata {
    OwnerMetadata(owner: owner, versions: versions.map { MetadataVersion(ascId: $0.0, owner: owner, number: $0.1, state: $0.2) },
                  localizations: texts.map {
                      LocalizationRow(ascId: "loc-\($0.versionId)-\($0.locale)", owner: owner, versionId: $0.versionId, locale: $0.locale,
                                      text: LocalizationText(name: "Yearly"))
                  })
}

/// Both owners with their created version in preparation (sv-3, iv-2) and no texts in it.
private let editable: [LocalizationOwner: OwnerMetadata] = [
    yearlyOwner: ownerMetadata(yearlyOwner, [("sv-2", 2, .approved), ("sv-3", 3, .prepareForSubmission)]),
    lifetimeOwner: ownerMetadata(lifetimeOwner, [("iv-1", 1, .approved), ("iv-2", 2, .prepareForSubmission)]),
]

@Suite("Ready for review (L3)")
struct ReadyForReviewTests {
    @Test func theCallToActionIsOnePlainSentence() {
        #expect(ReadyForReview.callToAction == "Ready for review: submit in App Store Connect")
        #expect(ReadyForReview.incompleteMessage == "Not ready: some texts were not written; replan the rest first (replan_rest).")
    }

    @Test func aFinishedPlanListsTheOwnersOfItsWrittenVersions() {
        let items = [versionItem(yearlyOwner, seq: 1, number: 3, state: .effective, ascId: "sv-3"),
                     versionItem(lifetimeOwner, seq: 5, number: 2, state: .done, ascId: "iv-2")]
        for state in [PlanState.effective, .scheduled, .partiallyApplied, .closed] {
            #expect(ReadyForReview.owners(plan: storedPlan(state), items: items, metadata: editable) == [lifetimeOwner, yearlyOwner])
        }
    }

    @Test func unfinishedPlansUnwrittenVersionsAndUnknownVersionsShowNothing() {
        let written = [versionItem(yearlyOwner, seq: 1, number: 3, state: .done, ascId: "sv-3")]
        for state in [PlanState.draft, .applying, .stale, .cancelled] {
            #expect(ReadyForReview.status(plan: storedPlan(state), items: written, metadata: editable) == ReadyForReview.Status(ready: [], incomplete: []))
        }
        for itemState in [ItemState.pending, .inFlight, .failed, .stale, .skipped, .mismatch] {
            let item = versionItem(yearlyOwner, seq: 1, number: 3, state: itemState, ascId: nil)
            #expect(ReadyForReview.status(plan: storedPlan(.partiallyApplied), items: [item], metadata: editable)
                        == ReadyForReview.Status(ready: [], incomplete: []))
        }
        // A snapshot that does not know the version (yet) decides nothing.
        #expect(ReadyForReview.status(plan: storedPlan(.effective), items: written, metadata: [:]) == ReadyForReview.Status(ready: [], incomplete: []))
        let other = [yearlyOwner: ownerMetadata(yearlyOwner, [("sv-2", 2, .approved), ("sv-9", 3, .prepareForSubmission)])]
        #expect(ReadyForReview.status(plan: storedPlan(.effective), items: written, metadata: other) == ReadyForReview.Status(ready: [], incomplete: []))
    }

    @Test func anOwnerDropsOutOnceTheVersionIsInReviewOrApproved() {
        let items = [versionItem(yearlyOwner, seq: 1, number: 3, state: .effective, ascId: "sv-3")]
        let inReview = ownerMetadata(yearlyOwner, [("sv-2", 2, .approved), ("sv-3", 3, .waitingForReview)])
        let approved = ownerMetadata(yearlyOwner, [("sv-2", 2, .replacedWithNewVersion), ("sv-3", 3, .approved)])
        #expect(ReadyForReview.owners(plan: storedPlan(.effective), items: items, metadata: editable) == [yearlyOwner])
        #expect(ReadyForReview.owners(plan: storedPlan(.effective), items: items, metadata: [yearlyOwner: inReview]).isEmpty)
        #expect(ReadyForReview.owners(plan: storedPlan(.effective), items: items, metadata: [yearlyOwner: approved]).isEmpty)
    }

    @Test func anOwnerWhoseTextIsNotInTheVersionIsIncompleteNotReady() {
        // cs is written and in sv-3; de-DE did not land (its item is not Done or Effective) and the snapshot does not have it.
        let snapshot = [yearlyOwner: ownerMetadata(yearlyOwner, [("sv-2", 2, .approved), ("sv-3", 3, .prepareForSubmission)],
                                                   texts: [("sv-3", "cs")]),
                        lifetimeOwner: ownerMetadata(lifetimeOwner, [("iv-1", 1, .approved), ("iv-2", 2, .prepareForSubmission)],
                                                     texts: [("iv-2", "en-US")])]
        for germanState in [ItemState.failed, .stale, .skipped, .pending, .inFlight, .mismatch] {
            let items = [versionItem(yearlyOwner, seq: 1, number: 3, state: .effective, ascId: "sv-3"),
                         textItem(yearlyOwner, seq: 2, locale: "cs", state: .effective),
                         textItem(yearlyOwner, seq: 3, locale: "de-DE", state: germanState),
                         versionItem(lifetimeOwner, seq: 4, number: 2, state: .effective, ascId: "iv-2"),
                         textItem(lifetimeOwner, seq: 5, locale: "en-US", state: .effective)]
            #expect(ReadyForReview.status(plan: storedPlan(.partiallyApplied), items: items, metadata: snapshot)
                        == ReadyForReview.Status(ready: [lifetimeOwner], incomplete: [yearlyOwner]))
            #expect(ReadyForReview.owners(plan: storedPlan(.partiallyApplied), items: items, metadata: snapshot) == [lifetimeOwner])
        }
    }

    @Test func aMissingTextThatLaterAppearsInTheSnapshotMakesTheOwnerReady() {
        // As after replan_rest and a sync: the original plan is Closed, de-DE Failed, and the snapshot now has de-DE in sv-3.
        let items = [versionItem(yearlyOwner, seq: 1, number: 3, state: .effective, ascId: "sv-3"),
                     textItem(yearlyOwner, seq: 2, locale: "cs", state: .effective),
                     textItem(yearlyOwner, seq: 3, locale: "de-DE", state: .failed)]
        let before = [yearlyOwner: ownerMetadata(yearlyOwner, [("sv-2", 2, .approved), ("sv-3", 3, .prepareForSubmission)],
                                                 texts: [("sv-3", "cs")])]
        let after = [yearlyOwner: ownerMetadata(yearlyOwner, [("sv-2", 2, .approved), ("sv-3", 3, .prepareForSubmission)],
                                                texts: [("sv-3", "cs"), ("sv-3", "de-DE")])]
        #expect(ReadyForReview.status(plan: storedPlan(.partiallyApplied), items: items, metadata: before)
                    == ReadyForReview.Status(ready: [], incomplete: [yearlyOwner]))
        #expect(ReadyForReview.status(plan: storedPlan(.closed), items: items, metadata: after)
                    == ReadyForReview.Status(ready: [yearlyOwner], incomplete: []))
    }

    @Test func aWrittenTextThatALaterPlanChangedStillCountsAsLanded() {
        // Version and texts Effective; afterwards another plan changed en-US in the same editable version.
        let items = [versionItem(yearlyOwner, seq: 1, number: 3, state: .effective, ascId: "sv-3"),
                     textItem(yearlyOwner, seq: 2, locale: "en-US", state: .effective)]
        var changed = ownerMetadata(yearlyOwner, [("sv-2", 2, .approved), ("sv-3", 3, .prepareForSubmission)], texts: [("sv-3", "en-US")])
        changed.localizations[0].text = LocalizationText(name: "Yearly Plus (changed by a later plan)")
        #expect(!LocalizationSemantics.isSatisfied(SetLocalization(owner: yearlyOwner, locale: "en-US", text: LocalizationText(name: "Yearly"),
                                                                   localizationId: nil, versionId: nil),
                                                   live: changed.localizationCell(locale: "en-US")))
        #expect(ReadyForReview.status(plan: storedPlan(.effective), items: items, metadata: [yearlyOwner: changed])
                    == ReadyForReview.Status(ready: [yearlyOwner], incomplete: []))
    }

    @Test func aVersionThatWentToReviewIsInNeitherList() {
        let items = [versionItem(yearlyOwner, seq: 1, number: 3, state: .effective, ascId: "sv-3"),
                     textItem(yearlyOwner, seq: 2, locale: "de-DE", state: .failed)]
        let inReview = [yearlyOwner: ownerMetadata(yearlyOwner, [("sv-2", 2, .approved), ("sv-3", 3, .waitingForReview)])]
        #expect(ReadyForReview.status(plan: storedPlan(.partiallyApplied), items: items, metadata: inReview)
                    == ReadyForReview.Status(ready: [], incomplete: []))
    }

    @Test func textItemsAloneNeverCount() {
        let cell = CellKey.localization(owner: yearlyOwner, locale: "en-US")
        let item = PlannedItem(seq: 1, cell: cell,
                               payload: .setLocalization(SetLocalization(owner: yearlyOwner, locale: "en-US", text: LocalizationText(name: "Yearly"),
                                                                         localizationId: "loc-1", versionId: nil)),
                               before: .localization(live: nil, pending: nil, pendingVersion: nil),
                               target: .localization(live: nil, pending: nil, pendingVersion: nil))
        let stored = StoredItem(planId: "p1", item: item, state: .effective, attempts: 1, ascId: "loc-1", errorJSON: nil, verifiedAt: nil,
                                effectiveAt: nil, supersededBy: nil)
        #expect(ReadyForReview.owners(plan: storedPlan(.effective), items: [stored], metadata: editable).isEmpty)
    }
}
