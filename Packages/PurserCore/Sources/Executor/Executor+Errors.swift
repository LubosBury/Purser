import Foundation
import GRDB
import Domain
import Store
import Audit
import ASCClient
import Catalog

extension Executor {
    /// Automatic RATE/NETWORK waits per apply session: the 1-2-4-8-15 schedule plus four more 15-minute rounds.
    static let maxAutomaticWaits = AppleConstants.rateBackoffMinutes.count + 4

    /// `route` is the request that was sent (for a SET_TEXT item the resolved one).
    func receivedEvent(_ planId: String, _ item: PlannedItem, _ info: ErrorInfo, route: (method: String, path: String)) -> (Database) throws -> Void {
        let payload = HTTPReceivedPayload(method: route.method, path: route.path, status: info.status, outcome: "error", ascId: nil, error: info)
        let refs = Self.refs(planId, item)
        let audit = self.audit
        return { db in try audit.append(.httpReceived, refs: refs, payload: payload, in: db) }
    }

    /// Spec §6 signal table. Only ASCError reaches this point; anything else propagates like a crash.
    func handleWriteError(_ error: ASCError, seq: Int, route: (method: String, path: String), context: inout RunContext) async throws -> ItemStep {
        let planId = context.planId
        guard let stored = ledgers[planId]?[seq] else { return .next }
        let item = stored.item
        let info = ErrorInfo(error)
        let event = receivedEvent(planId, item, info, route: route)
        let retryAllowed = stored.attempts < AppleConstants.maxServerErrorAttempts

        switch ErrorClassifier.classify(error) {
        case .maybeApplied:
            // No reliable answer after HTTP_SENT: the item stays InFlight; only a fresh read decides, never a blind retry.
            try setItem(planId, seq, to: .inFlight, error: info, requestEvent: event)
            if case .createMetadataVersion = item.payload { return try await confirmVersionByRead(seq: seq, context: &context) }
            return try await resolveByRead(seq: seq, info: info, retryAllowed: retryAllowed, divergedState: .stale, context: &context)

        case .notSent:
            try setItem(planId, seq, to: .pending, error: info, note: "network error before the request left", requestEvent: event)
            try await pauseAndWait(.network, context: &context)
            _ = try await freshState(item.cell, context: &context)
            return .retry

        case .rateLimited:
            try setItem(planId, seq, to: .pending, error: info, note: "429 rate limit", requestEvent: event)
            try await pauseAndWait(.rate, context: &context)
            _ = try await freshState(item.cell, context: &context)
            return .retry

        case .serverError:
            try setItem(planId, seq, to: .inFlight, error: info, requestEvent: event)
            let step: ItemStep
            if case .createMetadataVersion = item.payload {
                step = try await confirmVersionByRead(seq: seq, context: &context)
            } else {
                step = try await resolveByRead(seq: seq, info: info, retryAllowed: retryAllowed, divergedState: .stale, context: &context)
            }
            try noteError(info, seq: seq, context: &context)
            return step

        case .unauthorized:
            if context.authRetried.insert(seq).inserted {
                try setItem(planId, seq, to: .pending, error: info, note: "401: retrying once with a new token", requestEvent: event)
                return .retry
            }
            try setItem(planId, seq, to: .pending, error: info, note: "401 again", requestEvent: event)
            throw try pausePlan(planId, .auth, note: "App Store Connect rejected the token twice")

        case .agreement:
            try setItem(planId, seq, to: .pending, error: info, note: "an agreement must be accepted in App Store Connect", requestEvent: event)
            throw try pausePlan(planId, .agreement, note: "The Account Holder must accept the pending agreement in App Store Connect")

        case .forbidden:
            try setItem(planId, seq, to: .pending, error: info, note: "403 forbidden", requestEvent: event)
            throw try pausePlan(planId, .auth, note: "App Store Connect returned 403")

        case .mustDeleteFuture:
            try setItem(planId, seq, to: .stale, error: info, note: "a future price change already exists in the cell", requestEvent: event)
            try skipDependents(of: seq, planId: planId, reason: "is stale")
            try noteError(info, seq: seq, context: &context)
            return .next

        case .onlyFutureDeletable:
            try setItem(planId, seq, to: .failed, error: info, note: "the change has started or is too close to its start", requestEvent: event)
            try skipDependents(of: seq, planId: planId, reason: "failed")
            try noteError(info, seq: seq, context: &context)
            return .next

        case let .conflict(status):
            if case .createMetadataVersion = item.payload {
                // Spec §7: Apple refuses a version (409) while the owner has a pending one. Whatever version the owner has
                // now, this plan did not create it, so its texts must not go into it unseen: Stale, the dependents wait for a
                // replan. Any other refusal is Stale for the same reason, without the guess about a pending version.
                let note = status == 409
                    ? "409: App Store Connect refused the new version; the owner may already have a pending version. Re-plan."
                    : "\(status): App Store Connect refused the new version. Re-plan."
                try setItem(planId, seq, to: .stale, error: info, note: note, requestEvent: event)
                try skipDependents(of: seq, planId: planId, reason: "is stale")
                try noteError(info, seq: seq, context: &context)
                return .next
            }
            try setItem(planId, seq, to: .inFlight, error: info, requestEvent: event)
            let step = try await resolveByRead(seq: seq, info: info, retryAllowed: false, divergedState: .failed, context: &context)
            try noteError(info, seq: seq, context: &context)
            return step

        case .refused:
            try setItem(planId, seq, to: .failed, error: info, note: "refused by the client: \(error)", requestEvent: event)
            try skipDependents(of: seq, planId: planId, reason: "failed")
            try noteError(info, seq: seq, context: &context)
            return .next
        }
    }

    /// Fresh read of the cell after an uncertain answer: found -> Done, unchanged -> retry or Failed, otherwise `divergedState`.
    func resolveByRead(seq: Int, info: ErrorInfo, retryAllowed: Bool, divergedState: ItemState,
                       context: inout RunContext) async throws -> ItemStep {
        let planId = context.planId
        guard let stored = ledgers[planId]?[seq] else { return .next }
        let live = try await freshState(stored.item.cell, context: &context)
        switch Reconciler.resolve(stored.item, live: live, today: today) {
        case let .targetFound(ascId):
            try setItem(planId, seq, to: .done, ascId: ascId, note: "fresh read found the target")
            context.view.set(stored.item.cell, Reconciler.fillCreated(stored.item.target, ascId: ascId))
            return .next
        case .unchanged:
            if retryAllowed {
                try setItem(planId, seq, to: .pending, note: "fresh read: not applied, retrying")
                return .retry
            }
            try setItem(planId, seq, to: .failed, error: info, note: "fresh read: not applied")
            try skipDependents(of: seq, planId: planId, reason: "failed")
            return .next
        case .diverged:
            try setItem(planId, seq, to: divergedState, error: info, note: "fresh read: live state differs from before and target")
            try skipDependents(of: seq, planId: planId, reason: divergedState == .stale ? "is stale" : "failed")
            return .next
        }
    }

    /// Reads the product and kind of `cell`; a failed read waits (waitAfterFailedRead) and is read again.
    func freshState(_ cell: CellKey, context: inout RunContext) async throws -> CellState {
        while true {
            do {
                context.view.apply(try await cellReader.read(cell, in: context.view.snapshot))
                return context.view.state(cell, today: today)
            } catch let error as ASCError {
                try await waitAfterFailedRead(error, context: &context)
            }
        }
    }

    /// Spec §6, the one policy for a failed read (nothing was sent): 429 waits RATE, 401 and 403 pause AUTH, anything else
    /// waits NETWORK. The caller then reads again: `freshState` in place, an item's own reads through `.retry` (`process`),
    /// so the loop checks pause and abort before the item goes on.
    func waitAfterFailedRead(_ error: ASCError, context: inout RunContext) async throws {
        switch ErrorClassifier.classify(error) {
        case .rateLimited:
            try await pauseAndWait(.rate, context: &context)
        case .unauthorized, .forbidden:
            throw try pausePlan(context.planId, .auth, note: "a read was refused: \(error)")
        default:
            try await pauseAndWait(.network, context: &context)
        }
    }

    /// RATE and NETWORK resume on their own within the session (spec §6); after `maxAutomaticWaits` the plan stays paused
    /// and only `resume` (always with Touch ID) continues it. `cause` goes into the audit note of the wait.
    func pauseAndWait(_ reason: PauseReason, cause: String? = nil, context: inout RunContext) async throws {
        let planId = context.planId
        guard context.rateAttempt < Self.maxAutomaticWaits else {
            throw try pausePlan(planId, reason, note: "still failing after \(Self.maxAutomaticWaits) automatic waits; resume with Touch ID")
        }
        let schedule = AppleConstants.rateBackoffMinutes
        let minutes = schedule[min(context.rateAttempt, schedule.count - 1)]
        context.rateAttempt += 1
        try setPlan(planId, to: .applying, pause: reason, note: "automatic wait \(minutes) min" + (cause.map { ": \($0)" } ?? ""))
        try await waitWithHeartbeat(planId, seconds: Double(minutes) * 60)
        try setPlan(planId, to: .applying, pause: nil, note: "automatic resume after \(reason.rawValue)")
    }

    /// Persists Paused(reason) and returns the loop exit to throw.
    func pausePlan(_ planId: String, _ reason: PauseReason, note: String) throws -> LoopExit {
        try setPlan(planId, to: .applying, pause: reason, note: note)
        return .paused(reason)
    }

    /// Spec §6 "Order of steps within one cell": when the second step of a pair is not written, the first step's item carries
    /// LOST_SCHEDULED_CHANGE (DELETE -> POST) or NO_OFFER (PATCH_END -> POST). Called by setItem for Failed/Stale/Skipped.
    func flagPredecessors(_ planId: String, of item: PlannedItem) throws {
        for dependency in item.dependsOn {
            guard let predecessor = try ledgers[planId]?[dependency] ?? store.items(planId: planId).first(where: { $0.item.seq == dependency }),
                  predecessor.item.cell == item.cell,
                  predecessor.state == .done || predecessor.state == .effective else { continue }
            let flag: ItemFlag
            switch predecessor.item.payload {
            case .deleteRegularPrice: flag = .lostScheduledChange
            case .endIntro: flag = .noOffer
            default: continue
            }
            guard !predecessor.item.flags.contains(flag) else { continue }
            try setItem(planId, dependency, to: predecessor.state, note: "\(flag.rawValue): seq \(item.seq) was not written",
                        mutate: { $0.item.flags.append(flag) })
        }
    }

    /// SYSTEMIC: the same error `systemicSameErrorStreak` times in a row, or errors on more than `systemicErrorShare` of the items.
    func noteError(_ info: ErrorInfo, seq: Int, context: inout RunContext) throws {
        if context.streakSignature == info.signature {
            context.streakCount += 1
        } else {
            context.streakSignature = info.signature
            context.streakCount = 1
        }
        context.erroredSeqs.insert(seq)
        let total = max(ledgers[context.planId]?.count ?? 1, 1)
        let share = Decimal(context.erroredSeqs.count) / Decimal(total)
        let streak = context.streakCount >= AppleConstants.systemicSameErrorStreak
        let spread = context.erroredSeqs.count >= AppleConstants.systemicSameErrorStreak && share > AppleConstants.systemicErrorShare
        guard streak || spread else { return }
        let note = streak ? "the same error \(context.streakCount) times in a row (\(info.signature))"
                          : "errors on \(context.erroredSeqs.count) of \(total) items"
        throw try pausePlan(context.planId, .systemic, note: note)
    }

    /// Drains InFlight items by reading, then Cancelled (0 writes) or PartiallyApplied (spec §6). A version POST that may
    /// have created a version counts as a write (L3).
    public func abort(planId: String) async throws -> PlanState {
        if running.contains(planId) {
            abortRequests.insert(planId)
            await withCheckedContinuation { continuation in loopWaiters[planId, default: []].append(continuation) }
        }
        let plan = try loadPlan(planId)
        guard plan.state == .applying else { return plan.state }
        return try await finishAbort(planId)
    }

    func finishAbort(_ planId: String) async throws -> PlanState {
        let ledger = try loadLedger(planId)
        guard let snapshot = try catalog.latestSnapshot() else { throw ExecutorError.noSnapshot }
        var view = LiveView(snapshot: snapshot)
        let today = self.today
        var mayHaveWritten = false
        for stored in ledger.values.sorted(by: { $0.item.seq < $1.item.seq }) where stored.state == .inFlight {
            view.apply(try await cellReader.read(stored.item.cell, in: view.snapshot))
            switch Reconciler.resolve(stored.item, live: view.state(stored.item.cell, today: today), today: today) {
            case let .targetFound(ascId):
                try setItem(planId, stored.item.seq, to: .done, ascId: ascId, note: "abort: target found by read")
            case .unchanged:
                if case .createMetadataVersion = stored.item.payload {
                    // L3, as preflight 2b on resume: the version may exist although the read does not show it yet.
                    try setItem(planId, stored.item.seq, to: .stale,
                                note: "abort: the version may already exist although this read does not show it; re-sync and re-plan")
                    mayHaveWritten = true
                    continue
                }
                try setItem(planId, stored.item.seq, to: .pending, note: "abort: read shows it was not applied")
            case .diverged:
                try setItem(planId, stored.item.seq, to: .stale, note: "abort: live state differs")
            }
        }
        for stored in (ledgers[planId] ?? [:]).values.sorted(by: { $0.item.seq < $1.item.seq }) where stored.state == .pending {
            try setItem(planId, stored.item.seq, to: .skipped, note: "aborted")
        }
        let written: Set<ItemState> = [.done, .mismatch, .effective, .superseded, .withdrawn]
        let wrote = mayHaveWritten || (ledgers[planId] ?? [:]).values.contains { written.contains($0.state) }
        let state: PlanState = wrote ? .partiallyApplied : .cancelled
        try setPlan(planId, to: state, pause: nil, endReason: wrote ? nil : .abortedNoWrites, note: "aborted")
        if !running.contains(planId) { ledgers[planId] = nil }
        return state
    }
}
