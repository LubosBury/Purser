import Foundation
import Testing
import Domain

@Suite struct LocalizationDomainTests {
    @Test func ownerKeyRoundTripsAndRejectsMalformedKeys() {
        let owner = LocalizationOwner.subscription("6500000001")
        #expect(owner.key == "S|6500000001")
        #expect(owner.description == "S|6500000001")
        #expect(LocalizationOwner(key: "S|6500000001") == owner)
        #expect(LocalizationOwner(key: "G|7000000001") == .group("7000000001"))
        #expect(LocalizationOwner(key: "I|6600000001") == .iap("6600000001"))
        for bad in ["", "S", "S|", "X|1", "S|1|2", "|1"] {
            #expect(LocalizationOwner(key: bad) == nil, "\(bad)")
        }
    }

    @Test func ownersSortByKindThenId() {
        let owners: [LocalizationOwner] = [.subscription("2"), .iap("9"), .group("5"), .subscription("1")]
        #expect(owners.sorted() == [.group("5"), .iap("9"), .subscription("1"), .subscription("2")])
    }

    @Test(arguments: [
        (MetadataVersionState.approved, MetadataVersionState.Role.live),
        (.accepted, .live),
        (.prepareForSubmission, .editable),
        (.readyForReview, .editable),
        (.rejected, .editable),
        (.developerRejected, .editable),
        (.waitingForReview, .inReview),
        (.inReview, .inReview),
        (.replacedWithNewVersion, .retired),
        (MetadataVersionState("SOMETHING_NEW"), .inReview),
    ])
    func everyStateHasItsRole(_ state: MetadataVersionState, _ role: MetadataVersionState.Role) {
        #expect(state.role == role)
    }

    @Test func versionStateEncodesAsItsPlainName() throws {
        let data = try JSONEncoder().encode([MetadataVersionState.approved, MetadataVersionState("SOMETHING_NEW")])
        #expect(String(decoding: data, as: UTF8.self) == #"["APPROVED","SOMETHING_NEW"]"#)
        #expect(try JSONDecoder().decode([MetadataVersionState].self, from: data) == [.approved, MetadataVersionState("SOMETHING_NEW")])
    }

    private func version(_ number: Int, _ state: MetadataVersionState, owner: LocalizationOwner = .subscription("sub-y")) -> MetadataVersion {
        MetadataVersion(ascId: "ver-\(number)", owner: owner, number: number, state: state)
    }

    private func row(_ versionId: String, _ locale: String) -> LocalizationRow {
        LocalizationRow(ascId: "loc-\(versionId)-\(locale)", owner: .subscription("sub-y"), versionId: versionId, locale: locale,
                        text: LocalizationText(name: "Yearly", description: "Every fruit"))
    }

    @Test func metadataSortsVersionsAndRows() {
        let metadata = OwnerMetadata(owner: .subscription("sub-y"),
                                     versions: [version(3, .waitingForReview), version(1, .replacedWithNewVersion), version(2, .approved)],
                                     localizations: [row("ver-3", "en-US"), row("ver-2", "en-US"), row("ver-2", "cs")])
        #expect(metadata.versions.map(\.number) == [1, 2, 3])
        #expect(metadata.localizations.map(\.ascId) == ["loc-ver-2-cs", "loc-ver-2-en-US", "loc-ver-3-en-US"])
    }

    @Test func liveIsTheNewestApprovedAndPendingMustBeNewer() {
        let approvedWithDraft = OwnerMetadata(owner: .subscription("sub-y"),
                                              versions: [version(1, .replacedWithNewVersion), version(2, .approved), version(3, .prepareForSubmission)],
                                              localizations: [])
        #expect(approvedWithDraft.liveVersion?.number == 2)
        #expect(approvedWithDraft.pendingVersion?.number == 3)

        let inReview = OwnerMetadata(owner: .subscription("sub-y"), versions: [version(1, .approved), version(2, .waitingForReview)], localizations: [])
        #expect(inReview.pendingVersion?.state == .waitingForReview)

        let neverSubmitted = OwnerMetadata(owner: .subscription("sub-n"), versions: [version(1, .prepareForSubmission)], localizations: [])
        #expect(neverSubmitted.liveVersion == nil)
        #expect(neverSubmitted.pendingVersion?.number == 1)

        let olderRejected = OwnerMetadata(owner: .subscription("sub-y"), versions: [version(1, .rejected), version(2, .approved)], localizations: [])
        #expect(olderRejected.liveVersion?.number == 2)
        #expect(olderRejected.pendingVersion == nil)

        let empty = OwnerMetadata(owner: .group("grp-1"), versions: [], localizations: [])
        #expect(empty.liveVersion == nil)
        #expect(empty.pendingVersion == nil)
    }

    @Test func metadataRoundTripsThroughJSON() throws {
        let metadata = OwnerMetadata(owner: .group("grp-1"), versions: [version(1, .approved, owner: .group("grp-1"))],
                                     localizations: [LocalizationRow(ascId: "loc-1", owner: .group("grp-1"), versionId: "ver-1", locale: "en-US",
                                                                     text: LocalizationText(name: "Premium", customAppName: "FruitJar"))])
        let back = try JSONDecoder().decode(OwnerMetadata.self, from: try JSONEncoder().encode(metadata))
        #expect(back == metadata)
        #expect(back.localizations.first?.text.description == nil)
        #expect(back.localizations.first?.text.customAppName == "FruitJar")
    }
}
