import Foundation
import Testing
import Domain
import Store
import Catalog
@testable import Executor
import PurserTestSupport

@Suite struct LocalizationPayloadWiringTests {
    let owner = LocalizationOwner.subscription("sub-1")

    func item() -> PlannedItem {
        let version = MetadataVersion(ascId: "ver-1", owner: owner, number: 1, state: .prepareForSubmission)
        return PlannedItem(seq: 1, cell: .localization(owner: owner, locale: "cs"),
                           payload: .setLocalization(SetLocalization(owner: owner, locale: "cs", text: LocalizationText(name: "Ovoce"),
                                                                     localizationId: nil, versionId: "ver-1")),
                           before: .localization(live: nil, pending: nil, pendingVersion: version),
                           target: .localization(live: nil, pending: nil, pendingVersion: version))
    }

    @Test func aTextIsEffectiveAsSoonAsItIsVerifiedAndHasNoDeadline() {
        let today = CalendarDate(iso: "2026-10-09")!
        #expect(ItemEffectiveness.immediately(item(), today: today))
        #expect(DeadlineCheck.violation(item(), productState: .approved, now: today.startOfDayUTC) == nil)
    }

    @Test func inASnapshotATextCountsOnlyWhenVerified() {
        let snapshot = SyntheticCatalog().snapshot()
        let today = SyntheticCatalog.today
        var stored = StoredItem(planId: "p1", item: item(), state: .done, attempts: 1, ascId: "loc-1", errorJSON: nil,
                                verifiedAt: nil, effectiveAt: nil, supersededBy: nil)
        #expect(!ItemEffectiveness.inSnapshot(stored, snapshot: snapshot, today: today))
        stored.verifiedAt = Date(timeIntervalSince1970: 0)
        #expect(ItemEffectiveness.inSnapshot(stored, snapshot: snapshot, today: today))
    }
}
