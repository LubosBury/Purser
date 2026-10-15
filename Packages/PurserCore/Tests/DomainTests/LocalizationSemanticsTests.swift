import Testing
import Domain

@Suite struct LocalizationSemanticsTests {
    let owner = LocalizationOwner.subscription("sub-1")
    var live: MetadataVersion { MetadataVersion(ascId: "ver-1", owner: owner, number: 1, state: .approved) }

    func version(_ state: MetadataVersionState, number: Int = 2) -> MetadataVersion {
        MetadataVersion(ascId: "ver-\(number)", owner: owner, number: number, state: state)
    }

    func row(_ id: String, version: String, name: String, description: String? = nil) -> LocalizationRow {
        LocalizationRow(ascId: id, owner: owner, versionId: version, locale: "en-US", text: LocalizationText(name: name, description: description))
    }

    @Test func effectiveTextIsThePendingRowWhenAVersionIsInPreparation() {
        let old = row("loc-1", version: "ver-1", name: "Old")
        let new = row("loc-2", version: "ver-2", name: "New")
        #expect(LocalizationSemantics.effectiveText(.localization(live: old, pending: new, pendingVersion: version(.prepareForSubmission)))?.name == "New")
        #expect(LocalizationSemantics.effectiveText(.localization(live: old, pending: nil, pendingVersion: version(.prepareForSubmission))) == nil)
        #expect(LocalizationSemantics.effectiveText(.localization(live: old, pending: nil, pendingVersion: nil))?.name == "Old")
        #expect(LocalizationSemantics.effectiveText(.promo(nil)) == nil)
    }

    @Test func aVersionThatMovedIntoReviewDoesNotMatch() {
        let old = row("loc-1", version: "ver-1", name: "Old")
        let new = row("loc-2", version: "ver-2", name: "New")
        let expected = CellState.localization(live: old, pending: new, pendingVersion: version(.prepareForSubmission))
        #expect(LocalizationSemantics.matches(live: expected, expected: expected))
        #expect(!LocalizationSemantics.matches(live: .localization(live: old, pending: new, pendingVersion: version(.waitingForReview)), expected: expected))
        #expect(!LocalizationSemantics.matches(live: .localization(live: old, pending: new, pendingVersion: version(.inReview)), expected: expected))
        // Approved meanwhile: the texts are live now, but the version in preparation is gone.
        #expect(!LocalizationSemantics.matches(live: .localization(live: row("loc-2", version: "ver-2", name: "New"), pending: nil, pendingVersion: nil),
                                               expected: expected))
    }

    @Test func aTextPlannedIntoAVersionThatWasApprovedDoesNotMatchTheNextVersion() {
        // Planned into editable ver-2. Then ver-2 was approved and ver-3 appeared with a copy of its texts: the same
        // effective text in an editable version, but not the version the item names.
        let planned = row("loc-2", version: "ver-2", name: "Same")
        let expected = CellState.localization(live: row("loc-1", version: "ver-1", name: "Old"), pending: planned,
                                              pendingVersion: version(.prepareForSubmission))
        let next = CellState.localization(live: planned, pending: row("loc-3", version: "ver-3", name: "Same"),
                                          pendingVersion: version(.prepareForSubmission, number: 3))
        #expect(LocalizationSemantics.effectiveText(next) == LocalizationSemantics.effectiveText(expected))
        #expect(!LocalizationSemantics.matches(live: next, expected: expected))
        // A POST planned into ver-2 (no row for the locale there) neither matches ver-3 without the row.
        #expect(!LocalizationSemantics.matches(live: .localization(live: nil, pending: nil, pendingVersion: version(.prepareForSubmission, number: 3)),
                                               expected: .localization(live: nil, pending: nil, pendingVersion: version(.prepareForSubmission))))
    }

    @Test func theSameVersionMarkedReadyForReviewStillMatches() {
        let pending = row("loc-2", version: "ver-2", name: "Same")
        let expected = CellState.localization(live: nil, pending: pending, pendingVersion: version(.prepareForSubmission))
        #expect(LocalizationSemantics.matches(live: .localization(live: nil, pending: pending, pendingVersion: version(.readyForReview)),
                                              expected: expected))
    }

    @Test func aCopyOfTheLiveTextsInANewVersionStillMatches() {
        let old = row("loc-1", version: "ver-1", name: "Old", description: "Same")
        let expected = CellState.localization(live: old, pending: nil, pendingVersion: nil)
        let copy = row("loc-9", version: "ver-2", name: "Old", description: "Same")
        #expect(LocalizationSemantics.matches(live: .localization(live: old, pending: copy, pendingVersion: version(.prepareForSubmission)),
                                              expected: expected))
        let changed = row("loc-9", version: "ver-2", name: "Changed in ASC", description: "Same")
        #expect(!LocalizationSemantics.matches(live: .localization(live: old, pending: changed, pendingVersion: version(.prepareForSubmission)),
                                               expected: expected))
        #expect(!LocalizationSemantics.matches(live: .promo(nil), expected: expected))
    }

    @Test func nilFieldsOfTheWriteAreNotCompared() {
        let pending = row("loc-2", version: "ver-2", name: "New", description: "Anything")
        let state = CellState.localization(live: nil, pending: pending, pendingVersion: version(.prepareForSubmission))
        let nameOnly = SetLocalization(owner: owner, locale: "en-US", text: LocalizationText(name: "New"), localizationId: "loc-2", versionId: nil)
        #expect(LocalizationSemantics.isSatisfied(nameOnly, live: state))
        var withDescription = nameOnly
        withDescription.text.description = "Other"
        #expect(!LocalizationSemantics.isSatisfied(withDescription, live: state))
        withDescription.text.description = "Anything"
        #expect(LocalizationSemantics.isSatisfied(withDescription, live: state))
        #expect(LocalizationSemantics.carries(LocalizationText(name: "G", customAppName: "App"), LocalizationText(name: "G")))
        #expect(!LocalizationSemantics.carries(nil, LocalizationText(name: "G")))
    }

    @Test func aTargetIsReachedOnlyInAnEditableVersionAndItsLocale() {
        let pending = row("loc-2", version: "ver-2", name: "New")
        let write = SetLocalization(owner: owner, locale: "en-US", text: LocalizationText(name: "New"), localizationId: "loc-2", versionId: nil)
        #expect(!LocalizationSemantics.isSatisfied(write, live: .localization(live: nil, pending: pending, pendingVersion: version(.waitingForReview))))
        #expect(!LocalizationSemantics.isSatisfied(write, live: .localization(live: pending, pending: nil, pendingVersion: nil)))
        var cs = write
        cs.locale = "cs"
        #expect(!LocalizationSemantics.isSatisfied(cs, live: .localization(live: nil, pending: pending, pendingVersion: version(.prepareForSubmission))))
    }

    @Test func versionExistsNeedsAnEditableVersion() {
        #expect(LocalizationSemantics.versionExists(.metadataVersion(version(.prepareForSubmission))))
        #expect(LocalizationSemantics.versionExists(.metadataVersion(version(.rejected))))
        #expect(!LocalizationSemantics.versionExists(.metadataVersion(version(.inReview))))
        #expect(!LocalizationSemantics.versionExists(.metadataVersion(nil)))
        #expect(LocalizationSemantics.versionExists(.localization(live: nil, pending: nil, pendingVersion: version(.readyForReview))))
    }
}
