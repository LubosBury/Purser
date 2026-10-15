import Foundation
import GRDB
import Domain
import Store
import Audit
import PurserSecurity
import ASCClient
import Catalog
import Policy
import Planner

/// The only component that writes plans to App Store Connect (spec §6, contract K10).
public actor Executor {
    let database: WorkspaceDatabase
    let config: WorkspaceConfig
    let reader: any ASCReading
    let writer: any ASCWriting
    let sync: SyncEngine
    let catalog: CatalogStore
    let policy: PolicyEngine
    let audit: AuditLog
    let gate: any BiometricGate
    let budget: RateBudget?
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    let store: PlanStore
    let preflight: Preflight
    let cellReader: CellReader
    private let eventStream: AsyncStream<ExecutorEvent>
    let eventContinuation: AsyncStream<ExecutorEvent>.Continuation

    var running: Set<String> = []
    var pauseRequests: [String: PauseReason] = [:]
    var abortRequests: Set<String> = []
    var loopWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var ledgers: [String: [Int: StoredItem]] = [:]
    var lastHeartbeat: [String: Date] = [:]
    var stepHook: (@Sendable (ExecutorStep) throws -> Void)?

    public init(database: WorkspaceDatabase, config: WorkspaceConfig, reader: any ASCReading, writer: any ASCWriting,
                sync: SyncEngine, catalog: CatalogStore, policy: PolicyEngine, audit: AuditLog, gate: any BiometricGate,
                budget: RateBudget? = nil,
                now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.database = database
        self.config = config
        self.reader = reader
        self.writer = writer
        self.sync = sync
        self.catalog = catalog
        self.policy = policy
        self.audit = audit
        self.gate = gate
        self.budget = budget
        self.now = now
        self.sleep = sleep
        self.store = PlanStore(database: database)
        self.preflight = Preflight(store: PlanStore(database: database), config: config, reader: reader, sync: sync,
                                   catalog: catalog, policy: policy, now: now)
        self.cellReader = CellReader(reader: reader)
        let pair = AsyncStream.makeStream(of: ExecutorEvent.self)
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
    }

    /// Single-consumer stream of plan, item and progress events.
    public nonisolated var events: AsyncStream<ExecutorEvent> { eventStream }

    #if DEBUG
    /// DEBUG only: tests and the S8 drills stop the executor at a step as if the process died.
    public func setStepHook(_ hook: (@Sendable (ExecutorStep) throws -> Void)?) { stepHook = hook }
    #endif

    var today: CalendarDate { CalendarDate.today(now: now()) }

    func step(_ step: ExecutorStep) throws { try stepHook?(step) }

    static func refs(_ planId: String, _ item: PlannedItem) -> [String: String] {
        ["plan": planId, "seq": String(item.seq), "cell": item.cell.storageKey]
    }

    func loadPlan(_ planId: String) throws -> StoredPlan {
        guard let plan = try store.plan(id: planId) else { throw ExecutorError.planNotFound(planId) }
        return plan
    }

    @discardableResult
    func loadLedger(_ planId: String) throws -> [Int: StoredItem] {
        let items = try store.items(planId: planId)
        let ledger = Dictionary(uniqueKeysWithValues: items.map { ($0.item.seq, $0) })
        ledgers[planId] = ledger
        return ledger
    }

    /// Plan transition (checked) and its audit event in one transaction.
    @discardableResult
    func setPlan(_ planId: String, to state: PlanState, pause: PauseReason?, endReason: PlanEndReason? = nil, note: String? = nil,
                 mutate: ((inout StoredPlan) -> Void)? = nil) throws -> StoredPlan {
        var plan = try loadPlan(planId)
        let from = plan.state
        let changed = from != state || plan.pauseReason != pause
        if changed { try PlanStateMachine.check(from: from, to: state) }
        try PlanStateMachine.checkPause(state: state, pause: pause)
        try PlanStateMachine.checkEndReason(state: state, reason: endReason)
        plan.state = state
        plan.pauseReason = pause
        plan.endReason = endReason
        plan.updatedAt = now()
        mutate?(&plan)
        let updated = plan
        let payload = PlanStatePayload(from: from.rawValue, to: state.rawValue, pause: pause?.rawValue, endReason: endReason?.rawValue, note: note)
        try database.writer.write { db in
            try store.update(updated, in: db)
            if changed { try audit.append(.planStateChanged, refs: ["plan": planId], payload: payload, in: db) }
        }
        if changed { eventContinuation.yield(.planState(planId: planId, state: state, pause: pause)) }
        return updated
    }

    /// Item transition (checked), its audit event and an optional request event (httpSent/httpReceived) in one transaction.
    /// The request event is appended last, so HTTP_SENT is the newest audit row when the request leaves. A change of the
    /// item's flags without a state change is audited as itemStateChanged with from == to.
    @discardableResult
    func setItem(_ planId: String, _ seq: Int, to state: ItemState, ascId: String? = nil, error: ErrorInfo? = nil, note: String? = nil,
                 requestEvent: ((Database) throws -> Void)? = nil, mutate: ((inout StoredItem) -> Void)? = nil) throws -> StoredItem {
        let cached = ledgers[planId]?[seq]
        guard var stored = try cached ?? store.items(planId: planId).first(where: { $0.item.seq == seq }) else {
            throw ExecutorError.corruptPlan("item \(seq) of plan \(planId) is missing")
        }
        let from = stored.state
        let flagsBefore = stored.item.flags
        if from != state { try ItemStateMachine.check(from: from, to: state) }
        stored.state = state
        if let ascId { stored.ascId = ascId }
        if let error { stored.errorJSON = try JSONCoding.string(error) }
        mutate?(&stored)
        let updated = stored
        let flagsChanged = updated.item.flags != flagsBefore
        let audited = from != state || flagsChanged
        let notes = [note, flagsChanged ? "flags \(updated.item.flags.map(\.rawValue).joined(separator: ","))" : nil].compactMap { $0 }
        let payload = ItemStatePayload(from: from.rawValue, to: state.rawValue, ascId: updated.ascId,
                                       note: notes.isEmpty ? nil : notes.joined(separator: "; "))
        let itemRefs = Self.refs(planId, updated.item)
        try database.writer.write { db in
            try store.update(updated, in: db)
            if audited { try audit.append(.itemStateChanged, refs: itemRefs, payload: payload, in: db) }
            try requestEvent?(db)
        }
        ledgers[planId]?[seq] = updated
        if from != state { eventContinuation.yield(.item(planId: planId, seq: seq, state: state)) }
        if from != state, state == .failed || state == .stale || state == .skipped { try flagPredecessors(planId, of: updated.item) }
        return updated
    }

    /// Marks every Pending item that (transitively) depends on `seq` as Skipped.
    func skipDependents(of seq: Int, planId: String, reason: String) throws {
        var frontier = [seq]
        var visited: Set<Int> = [seq]
        while let current = frontier.popLast() {
            let dependents = (ledgers[planId] ?? [:]).values
                .filter { $0.item.dependsOn.contains(current) && !visited.contains($0.item.seq) }
                .map(\.item.seq).sorted()
            for dependent in dependents {
                visited.insert(dependent)
                frontier.append(dependent)
                if ledgers[planId]?[dependent]?.state == .pending {
                    try setItem(planId, dependent, to: .skipped, note: "predecessor \(seq) \(reason)")
                }
            }
        }
    }

    func heartbeatIfDue(_ planId: String) throws {
        let current = now()
        if let last = lastHeartbeat[planId], current.timeIntervalSince(last) < AppleConstants.heartbeatSeconds { return }
        lastHeartbeat[planId] = current
        var plan = try loadPlan(planId)
        plan.heartbeatAt = current
        let updated = plan
        try database.writer.write { db in try store.update(updated, in: db) }
    }

    /// Sleeps in heartbeat-sized chunks so a long wait never looks like a crash.
    func waitWithHeartbeat(_ planId: String, seconds: TimeInterval) async throws {
        var remaining = seconds
        while remaining > 0 {
            let chunk = min(remaining, AppleConstants.heartbeatSeconds)
            try await sleep(.milliseconds(Int64(chunk * 1000)))
            remaining -= chunk
            try heartbeatIfDue(planId)
        }
    }

    func finishRunning(_ planId: String) {
        running.remove(planId)
        pauseRequests[planId] = nil
        ledgers[planId] = nil
        lastHeartbeat[planId] = nil
        for waiter in loopWaiters.removeValue(forKey: planId) ?? [] { waiter.resume() }
    }

    /// C2 risk class -> number of distinct cells.
    static func riskClasses(_ verdicts: [Verdict]) -> [String: Int] {
        var cells: [String: Set<String>] = [:]
        for verdict in verdicts where verdict.severity == .confirm(.c2) {
            guard let riskClass = verdict.riskClass else { continue }
            cells[riskClass, default: []].insert(verdict.cell?.storageKey ?? "plan")
        }
        return cells.mapValues(\.count)
    }

    func recordConfirmation(_ planId: String, request: ConfirmationRequest, response: ConfirmationResponse,
                            problems: [String], verdictHash: String) throws {
        try audit.append(.confirmation, refs: ["plan": planId], payload: ConfirmationPayload(
            level: request.level.rawValue, accepted: response.accepted && problems.isEmpty, problems: problems, reason: response.reason,
            acknowledgedExclusions: response.acknowledgedExclusions, checkedRiskClasses: response.checkedRiskClasses.sorted(),
            riskClasses: request.riskClasses, verdictHash: verdictHash, verdictHashChanged: request.verdictHashChanged,
            exceptions: request.verdicts.contains { $0.rule == IAPScheduleSpikeGateRule.exceptionId }
                ? [IAPScheduleSpikeGateRule.exceptionId.rawValue] : nil))
    }

    /// First item of each listed cell becomes Stale (its chain Skipped) and the plan becomes Stale; nothing was written.
    func markStale(_ planId: String, cells: Set<CellKey>, verdicts: [Verdict], note: String) throws {
        let ledger = try loadLedger(planId)
        for cell in cells.sorted(by: { $0.storageKey < $1.storageKey }) {
            guard let first = ledger.values.filter({ $0.item.cell == cell && $0.state == .pending })
                .min(by: { $0.item.seq < $1.item.seq }) else { continue }
            try setItem(planId, first.item.seq, to: .stale, note: note)
            try skipDependents(of: first.item.seq, planId: planId, reason: "is stale")
        }
        try setPlan(planId, to: .stale, pause: nil, note: note) { $0.verdicts = verdicts }
    }
}
