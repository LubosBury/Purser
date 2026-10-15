import Testing
import Domain
@testable import Executor

private let today = CalendarDate(iso: "2026-10-09")!
private let owner = LocalizationOwner.subscription("sub-1")
private let draft = MetadataVersion(ascId: "ver-2", owner: owner, number: 2, state: .prepareForSubmission)

private func row(_ id: String, _ locale: String, _ name: String) -> LocalizationRow {
    LocalizationRow(ascId: id, owner: owner, versionId: "ver-2", locale: locale, text: LocalizationText(name: name))
}

private func item(_ payload: SetLocalization, before: CellState, target: CellState) -> PlannedItem {
    PlannedItem(seq: 1, cell: .localization(owner: owner, locale: payload.locale), payload: .setLocalization(payload),
                before: before, target: target)
}

@Suite struct LocalizationReconcilerTests {
    @Test func aPatchIsFoundUnchangedOrDiverged() {
        let before = CellState.localization(live: nil, pending: row("loc-1", "en-US", "Old"), pendingVersion: draft)
        let target = CellState.localization(live: nil, pending: row("loc-1", "en-US", "New"), pendingVersion: draft)
        let patch = item(SetLocalization(owner: owner, locale: "en-US", text: LocalizationText(name: "New"), localizationId: "loc-1", versionId: nil),
                         before: before, target: target)
        #expect(Reconciler.resolve(patch, live: target, today: today) == .targetFound(ascId: "loc-1"))
        #expect(Reconciler.resolve(patch, live: before, today: today) == .unchanged)
        #expect(Reconciler.resolve(patch, live: .localization(live: nil, pending: row("loc-1", "en-US", "Else"), pendingVersion: draft),
                                   today: today) == .diverged)
        var inReview = draft
        inReview.state = .waitingForReview
        #expect(Reconciler.resolve(patch, live: .localization(live: nil, pending: row("loc-1", "en-US", "Old"), pendingVersion: inReview),
                                   today: today) == .diverged)
    }

    @Test func aPostFindsTheCreatedRowAndFillsItsId() {
        let before = CellState.localization(live: nil, pending: nil, pendingVersion: draft)
        let target = CellState.localization(live: nil, pending: row("", "cs", "Ovoce"), pendingVersion: draft)
        let post = item(SetLocalization(owner: owner, locale: "cs", text: LocalizationText(name: "Ovoce"), localizationId: nil, versionId: "ver-2"),
                        before: before, target: target)
        let live = CellState.localization(live: nil, pending: row("loc-77", "cs", "Ovoce"), pendingVersion: draft)
        #expect(Reconciler.resolve(post, live: live, today: today) == .targetFound(ascId: "loc-77"))
        #expect(Reconciler.fillCreated(target, ascId: "loc-77") == live)
        #expect(Reconciler.matches(live: live, expected: target, today: today))
        #expect(Reconciler.reached(post, live: live, today: today))
        #expect(!Reconciler.reached(post, live: before, today: today))
    }
}
