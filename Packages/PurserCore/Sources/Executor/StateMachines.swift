import Domain

public enum TransitionError: Error, Equatable, Sendable {
    case plan(from: PlanState, to: PlanState)
    case item(from: ItemState, to: ItemState)
    case pause(state: PlanState)
    case endReason(state: PlanState, reason: PlanEndReason?)
}

/// Spec §6 "Plan states". Pausing and resuming is applying -> applying with a different pause reason.
public enum PlanStateMachine {
    public static let transitions: [PlanState: Set<PlanState>] = [
        .draft: [.draft, .applying, .cancelled],
        .applying: [.applying, .draft, .stale, .scheduled, .effective, .partiallyApplied, .cancelled],
        .stale: [.draft, .cancelled],
        .scheduled: [.effective, .partiallyApplied, .cancelled],
        .effective: [],
        .partiallyApplied: [.closed],
        .closed: [],
        .cancelled: [],
    ]

    public static let terminal: Set<PlanState> = [.effective, .closed, .cancelled]

    /// `.replanned` under `.cancelled`: M1's PlanPersistence.replan stores the old Draft/Stale plan as Cancelled + replanned.
    public static let allowedEndReasons: [PlanState: Set<PlanEndReason>] = [
        .cancelled: [.superseded, .withdrawn, .replanned, .cancelledByUser, .abortedNoWrites],
        .closed: [.replanned, .withdrawn, .abandoned],
    ]

    public static func canTransition(from: PlanState, to: PlanState) -> Bool {
        transitions[from]?.contains(to) ?? false
    }

    public static func check(from: PlanState, to: PlanState) throws {
        guard canTransition(from: from, to: to) else { throw TransitionError.plan(from: from, to: to) }
    }

    /// A pause reason exists only on an applying plan.
    public static func checkPause(state: PlanState, pause: PauseReason?) throws {
        if pause != nil, state != .applying { throw TransitionError.pause(state: state) }
    }

    /// Cancelled and Closed need an end reason from their set; every other state has none.
    public static func checkEndReason(state: PlanState, reason: PlanEndReason?) throws {
        if let allowed = allowedEndReasons[state] {
            guard let reason, allowed.contains(reason) else { throw TransitionError.endReason(state: state, reason: reason) }
        } else if reason != nil {
            throw TransitionError.endReason(state: state, reason: reason)
        }
    }
}

/// Spec §6 "Item states".
public enum ItemStateMachine {
    public static let transitions: [ItemState: Set<ItemState>] = [
        .pending: [.inFlight, .done, .stale, .skipped],
        .inFlight: [.done, .failed, .pending, .stale],
        .done: [.mismatch, .effective, .superseded, .withdrawn],
        .mismatch: [.done, .superseded, .withdrawn],
        .failed: [], .stale: [], .skipped: [], .superseded: [], .withdrawn: [], .effective: [],
    ]

    public static let terminal: Set<ItemState> = [.failed, .stale, .skipped, .superseded, .withdrawn, .effective]

    public static func canTransition(from: ItemState, to: ItemState) -> Bool {
        transitions[from]?.contains(to) ?? false
    }

    public static func check(from: ItemState, to: ItemState) throws {
        guard canTransition(from: from, to: to) else { throw TransitionError.item(from: from, to: to) }
    }
}
