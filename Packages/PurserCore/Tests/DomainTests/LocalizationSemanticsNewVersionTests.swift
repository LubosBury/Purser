import Foundation
import Testing
import Domain

private let owner = LocalizationOwner.subscription("6500000001")
private let created = MetadataVersion(ascId: "sv-3", owner: owner, number: 3, state: .prepareForSubmission)
private let text = LocalizationText(name: "Yearly", description: "One year of fruit")
private let liveRow = LocalizationRow(ascId: "loc-2-en", owner: owner, versionId: "sv-2", locale: "en-US", text: text)
/// The cell as the Planner saw it: only the Live version.
private let planned = CellState.localization(live: liveRow, pending: nil, pendingVersion: nil)

/// A copy of the Live text in the new version already matches through `matches` (`aCopyOfTheLiveTextsInANewVersionStillMatches`);
/// these tests cover the missing copy.
@Suite("LocalizationSemantics after a new version (L3)")
struct LocalizationSemanticsNewVersionTests {
    @Test func aNewVersionWithoutTheRowMatchesOnlyUntilCopyingIsConfirmed() {
        let missing = CellState.localization(live: liveRow, pending: nil, pendingVersion: created)
        #expect(LocalizationSemantics.matchesMissingCopy(live: missing, expected: planned, copiesLocalizations: false))
        #expect(!LocalizationSemantics.matchesMissingCopy(live: missing, expected: planned, copiesLocalizations: true))
        #expect(LocalizationSemantics.matches(live: missing, expected: planned) == !AppleConstants.newVersionCopiesLocalizations)
    }

    @Test func aVersionInReviewOrAChangedLiveTextIsNotThisException() {
        var inReview = created
        inReview.state = .waitingForReview
        #expect(!LocalizationSemantics.matchesMissingCopy(live: .localization(live: liveRow, pending: nil, pendingVersion: inReview),
                                                          expected: planned, copiesLocalizations: false))
        var changed = liveRow
        changed.text.name = "Changed in App Store Connect"
        #expect(!LocalizationSemantics.matchesMissingCopy(live: .localization(live: changed, pending: nil, pendingVersion: created),
                                                          expected: planned, copiesLocalizations: false))
    }

    @Test func aVersionThatExistedWhenPlannedIsNotThisException() {
        let plannedWithVersion = CellState.localization(live: liveRow, pending: nil, pendingVersion: created)
        #expect(!LocalizationSemantics.matchesMissingCopy(live: plannedWithVersion, expected: plannedWithVersion, copiesLocalizations: false))
        #expect(!LocalizationSemantics.matchesMissingCopy(live: .promo(nil), expected: planned, copiesLocalizations: false))
    }
}
