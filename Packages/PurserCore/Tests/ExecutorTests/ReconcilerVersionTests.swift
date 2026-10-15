import Foundation
import Testing
import Domain
import Store
@testable import Executor

private let today = CalendarDate(iso: "2026-10-09")!
private let owner = LocalizationOwner.subscription("6500000001")
private let placeholder = MetadataVersion(ascId: "", owner: owner, number: 3, state: .prepareForSubmission)
private let created = MetadataVersion(ascId: "sv-3", owner: owner, number: 3, state: .prepareForSubmission)
private let versionItem = PlannedItem(seq: 1, cell: .metadataVersion(owner: owner), payload: .createMetadataVersion(owner: owner),
                                      before: .metadataVersion(nil), target: .metadataVersion(placeholder), rules: ["N5"])

private func stored(_ item: PlannedItem, _ state: ItemState, ascId: String?) -> StoredItem {
    StoredItem(planId: "p1", item: item, state: state, attempts: 1, ascId: ascId, errorJSON: nil, verifiedAt: nil, effectiveAt: nil,
               supersededBy: nil)
}

@Suite("Reconciler: new versions (L3)")
struct ReconcilerVersionTests {
    @Test func anEditablePendingVersionSatisfiesTheItemAndGivesItsId() {
        var inReview = created
        inReview.state = .inReview
        let payload = WritePayload.createMetadataVersion(owner: owner)
        #expect(Reconciler.isSatisfied(payload, live: .metadataVersion(created), today: today))
        #expect(!Reconciler.isSatisfied(payload, live: .metadataVersion(inReview), today: today))
        #expect(!Reconciler.isSatisfied(payload, live: .metadataVersion(nil), today: today))
        #expect(Reconciler.createdAscId(payload, live: .metadataVersion(created), today: today) == "sv-3")
        #expect(Reconciler.createdAscId(payload, live: .metadataVersion(inReview), today: today) == nil)
    }

    @Test func resolveFindsTheVersionOrSeesItDiverge() {
        var inReview = created
        inReview.state = .waitingForReview
        #expect(Reconciler.resolve(versionItem, live: .metadataVersion(created), today: today) == .targetFound(ascId: "sv-3"))
        #expect(Reconciler.resolve(versionItem, live: .metadataVersion(nil), today: today) == .unchanged)
        #expect(Reconciler.resolve(versionItem, live: .metadataVersion(inReview), today: today) == .diverged)
        #expect(Reconciler.fillCreated(.metadataVersion(placeholder), ascId: "sv-3") == .metadataVersion(created))
    }

    @Test func createdVersionsComeFromWrittenVersionItems() {
        let iapOwner = LocalizationOwner.iap("6600000001")
        let iapItem = PlannedItem(seq: 4, cell: .metadataVersion(owner: iapOwner), payload: .createMetadataVersion(owner: iapOwner),
                                  before: .metadataVersion(nil), target: .metadataVersion(nil))
        let groupOwner = LocalizationOwner.group("7000000001")
        let groupItem = PlannedItem(seq: 7, cell: .metadataVersion(owner: groupOwner), payload: .createMetadataVersion(owner: groupOwner),
                                    before: .metadataVersion(nil), target: .metadataVersion(nil))
        let ledger: [Int: StoredItem] = [
            1: stored(versionItem, .done, ascId: "sv-3"),
            4: stored(iapItem, .effective, ascId: "iv-2"),
            7: stored(groupItem, .inFlight, ascId: nil),
        ]
        #expect(Executor.createdVersions(in: ledger) == [owner: "sv-3", iapOwner: "iv-2"])
    }
}
