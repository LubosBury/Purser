import Testing
import Domain
import Executor

/// Independent copy of spec §6 so a typo in the production table fails the test.
private let expectedPlan: [PlanState: Set<PlanState>] = [
    .draft: [.draft, .applying, .cancelled],
    .applying: [.applying, .draft, .stale, .scheduled, .effective, .partiallyApplied, .cancelled],
    .stale: [.draft, .cancelled],
    .scheduled: [.effective, .partiallyApplied, .cancelled],
    .effective: [],
    .partiallyApplied: [.closed],
    .closed: [],
    .cancelled: [],
]

private let expectedItem: [ItemState: Set<ItemState>] = [
    .pending: [.inFlight, .done, .stale, .skipped],
    .inFlight: [.done, .failed, .pending, .stale],
    .done: [.mismatch, .effective, .superseded, .withdrawn],
    .mismatch: [.done, .superseded, .withdrawn],
    .failed: [], .stale: [], .skipped: [], .superseded: [], .withdrawn: [], .effective: [],
]

@Suite("State machines")
struct StateMachineTests {
    @Test(arguments: PlanState.allCases)
    func planRowMatchesSpec(from: PlanState) throws {
        for to in PlanState.allCases {
            let allowed = expectedPlan[from]!.contains(to)
            #expect(PlanStateMachine.canTransition(from: from, to: to) == allowed, "plan \(from) -> \(to)")
            if allowed {
                try PlanStateMachine.check(from: from, to: to)
            } else {
                #expect(throws: TransitionError.plan(from: from, to: to)) { try PlanStateMachine.check(from: from, to: to) }
            }
        }
    }

    @Test(arguments: ItemState.allCases)
    func itemRowMatchesSpec(from: ItemState) throws {
        for to in ItemState.allCases {
            let allowed = expectedItem[from]!.contains(to)
            #expect(ItemStateMachine.canTransition(from: from, to: to) == allowed, "item \(from) -> \(to)")
            if allowed {
                try ItemStateMachine.check(from: from, to: to)
            } else {
                #expect(throws: TransitionError.item(from: from, to: to)) { try ItemStateMachine.check(from: from, to: to) }
            }
        }
    }

    @Test func terminalStatesHaveNoExit() {
        #expect(PlanStateMachine.terminal == [.effective, .closed, .cancelled])
        for state in PlanStateMachine.terminal { #expect(PlanStateMachine.transitions[state] == []) }
        #expect(ItemStateMachine.terminal == [.failed, .stale, .skipped, .superseded, .withdrawn, .effective])
        for state in ItemStateMachine.terminal { #expect(ItemStateMachine.transitions[state] == []) }
    }

    @Test(arguments: PlanState.allCases)
    func pauseOnlyWhileApplying(state: PlanState) throws {
        try PlanStateMachine.checkPause(state: state, pause: nil)
        for reason in PauseReason.allCases {
            if state == .applying {
                try PlanStateMachine.checkPause(state: state, pause: reason)
            } else {
                #expect(throws: TransitionError.pause(state: state)) { try PlanStateMachine.checkPause(state: state, pause: reason) }
            }
        }
    }

    @Test func endReasonsBelongToCancelledAndClosed() throws {
        try PlanStateMachine.checkEndReason(state: .cancelled, reason: .abortedNoWrites)
        try PlanStateMachine.checkEndReason(state: .cancelled, reason: .superseded)
        try PlanStateMachine.checkEndReason(state: .cancelled, reason: .replanned)
        try PlanStateMachine.checkEndReason(state: .closed, reason: .replanned)
        try PlanStateMachine.checkEndReason(state: .closed, reason: .abandoned)
        try PlanStateMachine.checkEndReason(state: .scheduled, reason: nil)
        #expect(throws: TransitionError.endReason(state: .closed, reason: .abortedNoWrites)) {
            try PlanStateMachine.checkEndReason(state: .closed, reason: .abortedNoWrites)
        }
        #expect(throws: TransitionError.endReason(state: .closed, reason: nil)) {
            try PlanStateMachine.checkEndReason(state: .closed, reason: nil)
        }
        #expect(throws: TransitionError.endReason(state: .effective, reason: .replanned)) {
            try PlanStateMachine.checkEndReason(state: .effective, reason: .replanned)
        }
    }
}
