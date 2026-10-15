import Foundation
import Testing
import Domain
import Store
import Catalog
@testable import Executor
import PurserTestSupport

@Suite("Outcomes of a new version (L3)")
struct NewVersionOutcomeTests {
    @Test func aCreatedVersionIsEffectiveOnceVerifiedAndCountsAsPresentWhileTheOwnerIsUnknown() {
        let owner = LocalizationOwner.subscription("6500000001")
        let item = PlannedItem(seq: 1, cell: .metadataVersion(owner: owner), payload: .createMetadataVersion(owner: owner),
                               before: .metadataVersion(nil),
                               target: .metadataVersion(MetadataVersion(ascId: "", owner: owner, number: 2, state: .prepareForSubmission)))
        let today = SyntheticCatalog.today
        #expect(ItemEffectiveness.immediately(item, today: today))
        let snapshot = SyntheticCatalog().snapshot()
        let written = StoredItem(planId: "p1", item: item, state: .done, attempts: 1, ascId: "sv-1", errorJSON: nil,
                                 verifiedAt: nil, effectiveAt: nil, supersededBy: nil)
        #expect(!ItemEffectiveness.inSnapshot(written, snapshot: snapshot, today: today))
        var verified = written
        verified.verifiedAt = Date(timeIntervalSince1970: 0)
        #expect(ItemEffectiveness.inSnapshot(verified, snapshot: snapshot, today: today))
        #expect(ItemEffectiveness.stillPresent(written, snapshot: snapshot, today: today))
        var withoutId = written
        withoutId.ascId = nil
        #expect(!ItemEffectiveness.stillPresent(withoutId, snapshot: snapshot, today: today))
    }
}
