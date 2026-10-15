import Foundation
import Testing
import Domain
import Store
@testable import Planner
import PurserTestSupport

private func plan(_ id: String, _ state: PlanState, reason: String?, created: TimeInterval = 0) -> StoredPlan {
    StoredPlan(id: id, origin: .iap, specJSON: "{}", importJSON: nil, binding: PlanBinding(config: SyntheticCatalog.config()),
               baseSyncId: 1, state: state, pauseReason: nil, endReason: nil, planHash: "h", verdictHash: "v", verdicts: [], excluded: [],
               productStates: [:], reason: reason, confirmationLevel: .c1, appBuild: "test", estimateRequests: 1, estimateMinutes: 1,
               replanOf: nil, createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: created),
               heartbeatAt: nil)
}

private func spec(_ iapId: String) -> PlanSpec { .iap(IAPPlanSpec(iapId: iapId, baseTerritory: "USA", prices: [], startDate: nil)) }

private let specs: [(title: String, spec: PlanSpec)] = [
    ("Clone com.example.c of com.example.s: regular prices (apply first)", spec("a")),
    ("Clone com.example.c of com.example.s: intro FREE_TRIAL ONE_WEEK, at once", spec("b")),
    ("Clone com.example.c of com.example.s: promotional offer winback_AB3", spec("c")),
]

private func built(_ actions: [CloneDraftAction]) -> [String] {
    actions.compactMap { if case let .build(title, _) = $0 { return title } else { return nil } }
}

private func existing(_ actions: [CloneDraftAction]) -> [CloneDraftOutcome.Line] {
    actions.compactMap { if case let .exists(line) = $0 { return line } else { return nil } }
}

@Suite struct CloneDraftRetryTests {
    @Test func aDraftThatAlreadyExistsIsNotBuiltAgainAndIsReported() {
        let open = CloneDrafts.openPlans(in: [plan("p1", .draft, reason: specs[0].title)])
        let actions = CloneDrafts.actions(for: specs, open: open)
        #expect(built(actions) == [specs[1].title, specs[2].title])
        #expect(existing(actions) == [CloneDraftOutcome.Line(title: specs[0].title, planId: "p1", error: nil, note: "Draft already exists")])
    }

    @Test func aPlanThatIsNoLongerADraftIsReportedAsAPlan() {
        for state in [PlanState.applying, .stale, .scheduled, .partiallyApplied] {
            let actions = CloneDrafts.actions(for: specs, open: CloneDrafts.openPlans(in: [plan("p1", state, reason: specs[0].title)]))
            #expect(existing(actions) == [CloneDraftOutcome.Line(title: specs[0].title, planId: "p1", error: nil, note: "Plan already exists")],
                    "\(state)")
        }
    }

    @Test func aDraftThatFailedBeforeHasNoPlanSoARetryBuildsIt() {
        // The first pass built the first two drafts and failed on the third: only those two are stored.
        let stored = [plan("p1", .draft, reason: specs[0].title, created: 1), plan("p2", .draft, reason: specs[1].title, created: 2)]
        let actions = CloneDrafts.actions(for: specs, open: CloneDrafts.openPlans(in: stored))
        #expect(built(actions) == [specs[2].title])
        #expect(existing(actions).map(\.planId) == ["p1", "p2"])
    }

    @Test func aRetryAfterEveryDraftWasBuiltBuildsNothing() {
        let stored = specs.enumerated().map { plan("p\($0.offset)", .draft, reason: $0.element.title) }
        let actions = CloneDrafts.actions(for: specs, open: CloneDrafts.openPlans(in: stored))
        #expect(built(actions).isEmpty)
        #expect(existing(actions).count == 3)
    }

    @Test func aFirstPassBuildsEverySpec() {
        #expect(built(CloneDrafts.actions(for: specs, open: CloneDrafts.openPlans(in: []))) == specs.map(\.title))
    }

    @Test func theActionsKeepTheOrderOfApplication() {
        let open = CloneDrafts.openPlans(in: [plan("p2", .draft, reason: specs[1].title)])
        let titles = CloneDrafts.actions(for: specs, open: open).map { action -> String in
            switch action {
            case let .build(title, _): return title
            case let .exists(line): return line.title
            }
        }
        #expect(titles == specs.map(\.title))
    }

    @Test func aPlanThatEndedDoesNotStandInTheWayOfANewDraft() {
        for state in [PlanState.cancelled, .closed, .effective] {
            let open = CloneDrafts.openPlans(in: [plan("p1", state, reason: specs[0].title)])
            #expect(open.isEmpty, "\(state)")
            #expect(built(CloneDrafts.actions(for: specs, open: open)).count == 3, "\(state)")
        }
    }

    @Test func everyPlanThatHasNotEndedCounts() {
        for state in [PlanState.draft, .applying, .stale, .scheduled, .partiallyApplied] {
            #expect(CloneDrafts.openDrafts(in: [plan("p1", state, reason: specs[0].title)]) == [specs[0].title: "p1"], "\(state)")
        }
    }

    @Test func aPlanWithoutAReasonIsNotACloneDraft() {
        #expect(CloneDrafts.openDrafts(in: [plan("p1", .draft, reason: nil), plan("p2", .draft, reason: "Something else")])
                == ["Something else": "p2"])
    }

    @Test func theNewestPlanOfATitleIsTheOneNamed() {
        let open = CloneDrafts.openDrafts(in: [plan("old", .draft, reason: specs[0].title, created: 1),
                                               plan("new", .draft, reason: specs[0].title, created: 2)])
        #expect(open == [specs[0].title: "new"])
    }

    @Test func aCancelledDraftIsBuiltAgainWhileItsSiblingsAreKept() {
        // "Cancel and replace": the user cancelled the regular prices Draft and prepares the drafts again.
        let stored = [plan("p1", .cancelled, reason: specs[0].title, created: 1), plan("p2", .draft, reason: specs[1].title, created: 2)]
        let actions = CloneDrafts.actions(for: specs, open: CloneDrafts.openPlans(in: stored))
        #expect(built(actions) == [specs[0].title, specs[2].title])
        #expect(existing(actions).map(\.planId) == ["p2"])
    }
}
