import Foundation
import GRDB
import Domain
import Store
import Audit
import ASCClient
import Catalog
import Policy

/// Mutable state of one pass of the write loop.
struct RunContext: Sendable {
    let planId: String
    var view: LiveView
    var productStates: [String: ProductState]
    let startedAt: Date
    var processed = 0
    var streakSignature: String?
    var streakCount = 0
    var erroredSeqs: Set<Int> = []
    var rateAttempt = 0
    var authRetried: Set<Int> = []
}

enum ItemStep: Sendable { case next, retry }

/// Leaves the loop with the plan already persisted as Paused(reason).
enum LoopExit: Error { case paused(PauseReason) }

extension Executor {
    public func apply(planId: String,
                      confirm: @escaping @Sendable (ConfirmationRequest) async -> ConfirmationResponse) async throws -> PlanState {
        let plan = try loadPlan(planId)
        guard plan.state == .draft else { throw ExecutorError.invalidState(plan.state) }
        if let other = try store.plans(states: [.applying]).first(where: { $0.id != planId }) {
            throw ExecutorError.anotherPlanApplying(other.id)
        }
        try await gate.authenticate(reason: "Apply a price plan to \(config.name)")
        let started = now()
        try setPlan(planId, to: .applying, pause: nil, note: "apply started") { $0.heartbeatAt = started }
        running.insert(planId)
        lastHeartbeat[planId] = started
        defer { finishRunning(planId) }

        let outcome: PreflightOutcome
        do {
            outcome = try await preflight.run(planId: planId, mode: .firstStart)
        } catch let error as ExecutorError {
            if case .bindingMismatch = error {
                try markStale(planId, cells: [], verdicts: [Verdict(rule: "A1", severity: .block(.plan), cell: nil,
                                                                    message: "Plan binding does not match the workspace (\(error))")],
                              note: "A1 binding mismatch")
                return .stale
            }
            try setPlan(planId, to: .draft, pause: nil, note: "preflight failed: \(error)")
            throw error
        } catch let error as ASCError {
            try setPlan(planId, to: .draft, pause: nil, note: "preflight failed: \(error)")
            throw error
        }

        try setPlan(planId, to: .applying, pause: nil) { $0.productStates = outcome.productStates }
        if !outcome.planBlockers.isEmpty || !outcome.staleCells.isEmpty || !outcome.cellBlockers.isEmpty {
            try markStale(planId, cells: outcome.staleCells.union(outcome.cellBlockers.keys), verdicts: outcome.verdicts,
                          note: "preflight 2a: live state or verdicts changed")
            return .stale
        }

        let request = ConfirmationRequest(planId: planId, level: outcome.level, verdicts: outcome.verdicts, excluded: plan.excluded,
                                          riskClasses: Self.riskClasses(outcome.verdicts),
                                          verdictHashChanged: outcome.verdictHashChanged, appName: config.name)
        let response = await confirm(request)
        let problems = ConfirmationValidator.problems(request: request, response: response)
        try recordConfirmation(planId, request: request, response: response, problems: problems, verdictHash: outcome.verdictHash)
        guard problems.isEmpty else {
            try setPlan(planId, to: .draft, pause: nil, note: "confirmation rejected: \(problems.joined(separator: "; "))")
            return .draft
        }
        try setPlan(planId, to: .applying, pause: nil) { stored in
            stored.reason = response.reason
            stored.verdicts = outcome.verdicts
            stored.verdictHash = outcome.verdictHash
            stored.confirmationLevel = outcome.level
        }
        return try await runLoop(planId: planId, snapshot: outcome.snapshot)
    }

    public func resume(planId: String,
                       confirm: @escaping @Sendable (ConfirmationRequest) async -> ConfirmationResponse) async throws -> PlanState {
        let plan = try loadPlan(planId)
        guard plan.state == .applying, let reason = plan.pauseReason, !running.contains(planId) else {
            throw ExecutorError.invalidState(plan.state)
        }
        // Always Touch ID (spec D2, §4): automatic RATE/NETWORK resumes happen inside runLoop (pauseAndWait), never through
        // resume(), so a RATE/NETWORK pause that outlived its apply session (or a crash) still needs the owner.
        try await gate.authenticate(reason: "Resume a price plan on \(config.name)")
        running.insert(planId)
        lastHeartbeat[planId] = now()
        defer { finishRunning(planId) }

        let outcome = try await preflight.run(planId: planId, mode: .resume)
        try loadLedger(planId)
        let beat = now()
        try setPlan(planId, to: .applying, pause: reason) { stored in
            stored.productStates = outcome.productStates
            stored.heartbeatAt = beat
        }
        for change in outcome.itemChanges {
            try setItem(planId, change.seq, to: change.to, ascId: change.ascId, note: change.note)
            if change.to == .stale { try skipDependents(of: change.seq, planId: planId, reason: "is stale") }
        }
        for cell in outcome.cellBlockers.keys.sorted(by: { $0.storageKey < $1.storageKey }) {
            guard let first = (ledgers[planId] ?? [:]).values.filter({ $0.item.cell == cell && $0.state == .pending })
                .min(by: { $0.item.seq < $1.item.seq }) else { continue }
            let rules = (outcome.cellBlockers[cell] ?? []).map(\.rule.rawValue).joined(separator: ", ")
            try setItem(planId, first.item.seq, to: .stale, note: "blocked by \(rules)")
            try skipDependents(of: first.item.seq, planId: planId, reason: "is stale")
        }
        guard outcome.planBlockers.isEmpty else { throw ExecutorError.blocked(outcome.planBlockers.map(\.rule)) }

        if outcome.verdictHashChanged {
            let request = ConfirmationRequest(planId: planId, level: outcome.level, verdicts: outcome.verdicts, excluded: plan.excluded,
                                              riskClasses: Self.riskClasses(outcome.verdicts), verdictHashChanged: true,
                                              appName: config.name)
            let response = await confirm(request)
            let problems = ConfirmationValidator.problems(request: request, response: response)
            try recordConfirmation(planId, request: request, response: response, problems: problems, verdictHash: outcome.verdictHash)
            guard problems.isEmpty else {
                try setPlan(planId, to: .applying, pause: .user, note: "confirmation on resume rejected")
                return .applying
            }
            try setPlan(planId, to: .applying, pause: reason) { stored in
                stored.verdicts = outcome.verdicts
                stored.verdictHash = outcome.verdictHash
                stored.confirmationLevel = outcome.level
                if let text = response.reason { stored.reason = text }
            }
        }
        try setPlan(planId, to: .applying, pause: nil, note: "resumed after \(reason.rawValue)")
        return try await runLoop(planId: planId, snapshot: outcome.snapshot)
    }

    /// Running plans pause at the next item boundary (an in-flight request finishes first).
    public func pause(planId: String, reason: PauseReason) async {
        if running.contains(planId) {
            pauseRequests[planId] = reason
            return
        }
        guard let plan = try? store.plan(id: planId), plan.state == .applying, plan.pauseReason == nil else { return }
        _ = try? setPlan(planId, to: .applying, pause: reason, note: "paused")
    }

    static func productOrder(_ ledger: [Int: StoredItem]) -> [String] {
        var first: [String: Int] = [:]
        for (seq, stored) in ledger {
            let product = stored.item.cell.productAscId
            first[product] = min(first[product] ?? seq, seq)
        }
        return first.sorted { $0.value < $1.value }.map(\.key)
    }

    func runLoop(planId: String, snapshot: CatalogSnapshot) async throws -> PlanState {
        let ledger = try loadLedger(planId)
        let plan = try loadPlan(planId)
        var context = RunContext(planId: planId, view: LiveView(snapshot: snapshot), productStates: plan.productStates, startedAt: now())
        do {
            for product in Self.productOrder(ledger) {
                let seqs = ledger.values.filter { $0.item.cell.productAscId == product }.map(\.item.seq).sorted()
                for seq in seqs where ledgers[planId]?[seq]?.state == .pending {
                    if let exit = try await checkInterrupts(planId) { return exit }
                    try heartbeatIfDue(planId)
                    while try await process(seq: seq, context: &context) == .retry {
                        if let exit = try await checkInterrupts(planId) { return exit }
                        try heartbeatIfDue(planId)
                    }
                    context.processed += 1
                    await emitProgress(planId, context: context)
                }
                if let exit = try await checkInterrupts(planId) { return exit }
                try await verify(product: product, context: &context)
            }
        } catch is LoopExit {
            return .applying
        }
        return try finishPlan(planId)
    }

    func checkInterrupts(_ planId: String) async throws -> PlanState? {
        if abortRequests.remove(planId) != nil { return try await finishAbort(planId) }
        if let reason = pauseRequests.removeValue(forKey: planId) {
            try setPlan(planId, to: .applying, pause: reason, note: "paused")
            return .applying
        }
        return nil
    }

    /// One attempt at one item (spec §6 step 4).
    func process(seq: Int, context: inout RunContext) async throws -> ItemStep {
        let planId = context.planId
        guard let stored = ledgers[planId]?[seq], stored.state == .pending else { return .next }
        let item = stored.item

        for dependency in item.dependsOn {
            let state = ledgers[planId]?[dependency]?.state
            if state != .done && state != .effective {
                try setItem(planId, seq, to: .skipped, note: "predecessor \(dependency) is \(state?.rawValue ?? "missing")")
                try skipDependents(of: seq, planId: planId, reason: "was skipped")
                return .next
            }
        }

        if let violation = DeadlineCheck.violation(item, productState: context.productStates[item.cell.productAscId], now: now()) {
            try setItem(planId, seq, to: .stale, note: violation)
            try skipDependents(of: seq, planId: planId, reason: "is stale")
            return .next
        }

        let today = self.today
        switch Reconciler.resolve(item, live: context.view.state(item.cell, today: today), today: today) {
        case let .targetFound(ascId):
            try setItem(planId, seq, to: .done, ascId: ascId, note: "reconciled: target already present")
            context.view.set(item.cell, Reconciler.fillCreated(item.target, ascId: ascId))
            return .next
        case .diverged:
            try setItem(planId, seq, to: .stale, note: "live state differs from before")
            try skipDependents(of: seq, planId: planId, reason: "is stale")
            return .next
        case .unchanged:
            break
        }

        let route = WritePaths.request(for: item.payload)
        let body: Data?
        do {
            body = try WriteBodies.body(for: item.payload)?.data()
        } catch let error as WriteBodyError {
            // STRUCT rule (R1, I1, I3, O4, L1): such a request cannot be built, so it never leaves; re-plan fixes it.
            try setItem(planId, seq, to: .stale, note: "request cannot be built: \(error)")
            try skipDependents(of: seq, planId: planId, reason: "is stale")
            return .next
        }

        // K5: ASCHTTPClient does not pace writes; the Executor draws from the workspace budget right before each write.
        if let budget { try await budget.acquire(forVerify: false) }
        try step(.beforeSend(seq: seq))
        // Spec §5: the audit keeps keyId and jti, never the token; ASCHTTPClient puts this jti into the request's token.
        let tokenId = UUID().uuidString
        let sent = HTTPSentPayload(method: route.method, path: route.path, op: item.op.rawValue, naturalKey: item.naturalKey,
                                   attempt: stored.attempts + 1, body: body.map { String(decoding: $0, as: UTF8.self) },
                                   keyId: config.keyId, jti: tokenId)
        let refs = Self.refs(planId, item)
        let audit = self.audit
        try setItem(planId, seq, to: .inFlight, note: "sending", requestEvent: { db in
            try audit.append(.httpSent, refs: refs, payload: sent, in: db)
        }, mutate: { $0.attempts += 1 })
        try step(.afterHTTPSent(seq: seq))

        let createdId: String?
        do {
            let payload = item.payload
            createdId = try await ASCRequestContext.$tokenId.withValue(tokenId) { try await self.send(payload) }
        } catch let error as ASCError {
            return try await handleWriteError(error, seq: seq, context: &context)
        }
        try step(.afterResponse(seq: seq))

        let received = HTTPReceivedPayload(method: route.method, path: route.path, status: nil, outcome: "ok", ascId: createdId, error: nil)
        try setItem(planId, seq, to: .done, ascId: createdId, note: "written", requestEvent: { db in
            try audit.append(.httpReceived, refs: refs, payload: received, in: db)
        })
        context.view.set(item.cell, Reconciler.fillCreated(item.target, ascId: createdId))
        context.streakSignature = nil
        context.streakCount = 0
        context.rateAttempt = 0
        try step(.afterItemCommitted(seq: seq))
        return .next
    }

    /// Exactly one ASC request; returns the id of a created row, offer or nothing.
    func send(_ payload: WritePayload) async throws -> String? {
        switch payload {
        case let .createRegularPrice(request): return try await writer.createRegularPrice(request).ascId
        case let .deleteRegularPrice(ascId): try await writer.deleteRegularPrice(ascId: ascId); return nil
        case let .createIntro(request): return try await writer.createIntroductoryOffer(request).ascId
        case let .endIntro(ascId, endDate): try await writer.endIntroductoryOffer(ascId: ascId, endDate: endDate); return nil
        case let .deleteIntro(ascId): try await writer.deleteIntroductoryOffer(ascId: ascId); return nil
        case let .createPromo(request): return try await writer.createPromotionalOffer(request).ascId
        case let .replacePromoPrices(ascId, prices): try await writer.replacePromotionalOfferPrices(ascId: ascId, prices: prices); return nil
        case let .deletePromo(ascId): try await writer.deletePromotionalOffer(ascId: ascId); return nil
        case let .replaceIAPSchedule(request): try await writer.replaceIAPPriceSchedule(request); return nil
        }
    }

    /// Spec §6 step 5: up to `verifyAttempts` reads of the product within `verifyWindowSeconds`; not found = Mismatch.
    func verify(product: String, context: inout RunContext) async throws {
        let planId = context.planId
        var missing = Set((ledgers[planId] ?? [:]).values
            .filter { $0.item.cell.productAscId == product && $0.state == .done && $0.verifiedAt == nil }
            .map(\.item.seq))
        guard !missing.isEmpty else { return }
        try step(.beforeVerify(product: product))
        let spacing = AppleConstants.verifyWindowSeconds / Double(max(AppleConstants.verifyAttempts - 1, 1))
        for attempt in 1...AppleConstants.verifyAttempts {
            if attempt > 1 { try await waitWithHeartbeat(planId, seconds: spacing) }
            guard let snapshot = try await verifyRead(product) else { continue }
            context.view.replace(snapshot: snapshot)
            let today = self.today
            var verified: [Int] = []
            for seq in missing.sorted() {
                guard let stored = ledgers[planId]?[seq] else { continue }
                if Reconciler.reached(stored.item, live: snapshot.cellState(stored.item.cell, on: today), today: today) {
                    let at = now()
                    try setItem(planId, seq, to: .done, mutate: { $0.verifiedAt = at })
                    verified.append(seq)
                }
            }
            missing.subtract(verified)
            try audit.append(.verify, refs: ["plan": planId, "product": product],
                             payload: VerifyPayload(product: product, attempt: attempt, verified: verified, missing: missing.sorted(), late: false))
            if missing.isEmpty { break }
        }
        for seq in missing.sorted() {
            try setItem(planId, seq, to: .mismatch, note: "target not found after \(AppleConstants.verifyAttempts) reads")
        }
        try step(.afterVerify(product: product))
    }

    /// One verify read through SyncEngine (observations get recorded); nil when the read failed or was incomplete.
    func verifyRead(_ product: String) async throws -> CatalogSnapshot? {
        do {
            let result = try await sync.sync(trigger: .verify, scope: .products([product]))
            guard result.status == .complete else { return nil }
            return try catalog.latestSnapshot()
        } catch is ASCError {
            return nil
        }
    }

    func emitProgress(_ planId: String, context: RunContext) async {
        let ledger = ledgers[planId] ?? [:]
        let finished = ledger.values.filter { $0.state != .pending && $0.state != .inFlight }.count
        let left = ledger.count - finished
        let elapsed = now().timeIntervalSince(context.startedAt)
        let eta: Int? = context.processed > 0 ? Int((Double(left) * elapsed / Double(context.processed) / 60).rounded(.up)) : nil
        let remaining = await budget?.latest?.remaining
        eventContinuation.yield(.progress(planId: planId, done: finished, total: ledger.count, budgetRemaining: remaining, etaMinutes: eta))
    }

    func finishPlan(_ planId: String) throws -> PlanState {
        let today = self.today
        for stored in (ledgers[planId] ?? [:]).values.sorted(by: { $0.item.seq < $1.item.seq })
        where stored.state == .done && stored.verifiedAt != nil && ItemEffectiveness.immediately(stored.item, today: today) {
            let at = now()
            try setItem(planId, stored.item.seq, to: .effective, note: "effective after verify", mutate: { $0.effectiveAt = at })
        }
        let state = OutcomeCalculator.afterApply(Array((ledgers[planId] ?? [:]).values))
        try setPlan(planId, to: state, pause: nil, note: "apply finished")
        return state
    }
}
