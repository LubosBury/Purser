import AppKit
import Foundation
import Observation
import Domain
import Executor
import PurserSecurity

/// An apply or resume started without the owner at the Mac: who answers the confirmation and which gate stands in
/// for Touch ID.
struct DelegatedApply: Sendable {
    let confirm: @Sendable (ConfirmationRequest) async -> ConfirmationResponse
    let gate: any BiometricGate
}

/// Drives apply/resume/pause/abort and the plan actions of one workspace and mirrors executor events for the UI.
/// Owned by WorkspaceSession (one per session), so view re-renders and lock/unlock never create a second controller.
@MainActor @Observable
final class ApplyController {
    enum Phase: Equatable {
        case idle
        case running(planId: String)
        case paused(planId: String, reason: PauseReason)
        case finished(planId: String, state: PlanState)
        case failed(planId: String, message: String)
    }

    /// The controller of the workspace on screen (AppDelegate: Cmd-Q pauses with QUIT; AppModel: locking cancels a pending
    /// confirmation). Set by WorkspaceApplyHost.onAppear, never by init.
    static weak var current: ApplyController?

    private(set) var phase: Phase = .idle
    private(set) var done = 0
    private(set) var total = 0
    private(set) var budgetRemaining: Int?
    private(set) var etaMinutes: Int?
    private(set) var isWorking = false
    private(set) var actionMessage: String?
    let broker = ConfirmationBroker()

    private let session: WorkspaceSession
    private let notifier = Notifier()
    private let keepAwake = KeepAwake()
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    init(session: WorkspaceSession) {
        self.session = session
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.handleWake() }
        }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var activePlanId: String? {
        switch phase {
        case let .running(planId), let .paused(planId, _): return planId
        default: return nil
        }
    }

    /// `delegated` nil = the owner at the Mac: the confirmation sheet and Touch ID. A call over the MCP bridge brings
    /// its own confirmation answer and gate (MCPToolRouter).
    func apply(planId: String, delegated: DelegatedApply? = nil) {
        start(planId, delegated) { session, confirm, gate, onEvent in
            try await session.apply(planId: planId, confirm: confirm, gate: gate, onEvent: onEvent)
        }
    }

    func resume(planId: String, delegated: DelegatedApply? = nil) {
        start(planId, delegated) { session, confirm, gate, onEvent in
            try await session.resume(planId: planId, confirm: confirm, gate: gate, onEvent: onEvent)
        }
    }

    func pause() {
        guard let planId = activePlanId else { return }
        Task { await session.pause(planId: planId, reason: .user) }
    }

    func abort(planId: String) {
        Task {
            do {
                let state = try await session.abort(planId: planId)
                settle(planId: planId, returned: state)
            } catch {
                phase = .failed(planId: planId, message: String(describing: error))
            }
            refreshPlanScreen(planId)
        }
    }

    /// Cmd-Q during apply: pause with QUIT and wait up to 10 s for the in-flight request to finish.
    func pauseForQuit() async {
        guard case let .running(planId) = phase else { return }
        await session.pause(planId: planId, reason: .quit)
        for _ in 0..<100 where isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Plan actions (spec §6 PartiallyApplied, §8 "Roll back"); none of them writes to ASC

    func withdraw(planId: String) {
        runAction { try await self.session.withdrawWritten(planId: planId) }
    }

    func replanRest(planId: String) {
        runAction { try await self.session.replanRest(planId: planId) }
    }

    func closePlan(planId: String, reason: String) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await session.closePlan(planId: planId, reason: reason)
                actionMessage = "Plan closed; the reason is in the audit."
                refreshPlanScreen(planId)
            } catch {
                actionMessage = "Not closed: \(error)"
            }
        }
    }

    /// Called by WorkspaceSession.close(): pauses a running apply, stops the wake observer and any keep-awake assertion.
    func shutdown() {
        if isRunning, let planId = activePlanId, let executor = session.activeExecutor {
            Task { await executor.pause(planId: planId, reason: .user) }
        }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        broker.cancelIfWaiting()
        keepAwake.end()
        if ApplyController.current === self { ApplyController.current = nil }
    }

    // MARK: Internals

    private typealias Operation = (WorkspaceSession,
                                   @escaping @Sendable (ConfirmationRequest) async -> ConfirmationResponse,
                                   (any BiometricGate)?,
                                   @escaping @MainActor (ExecutorEvent) -> Void) async throws -> PlanState

    private func start(_ planId: String, _ delegated: DelegatedApply?, _ operation: @escaping Operation) {
        guard !isRunning else { return }
        phase = .running(planId: planId)
        done = 0
        total = 0
        budgetRemaining = nil
        etaMinutes = nil
        actionMessage = nil
        notifier.requestAuthorization()
        keepAwake.begin(reason: "Purser is applying a price plan")
        Task { [weak self] in
            guard let self else { return }
            defer { self.keepAwake.end() }
            let broker = self.broker
            let askOwner: @Sendable (ConfirmationRequest) async -> ConfirmationResponse = { request in await broker.ask(request) }
            let confirm = delegated?.confirm ?? askOwner
            do {
                let state = try await operation(self.session, confirm, delegated?.gate, { event in self.handle(event) })
                self.settle(planId: planId, returned: state)
            } catch {
                self.phase = .failed(planId: planId, message: String(describing: error))
                self.notifier.applyFailed(workspace: self.session.config.name, message: String(describing: error))
            }
            self.refreshPlanScreen(planId)
        }
    }

    func handle(_ event: ExecutorEvent) {
        switch event {
        case let .progress(_, done, total, budget, eta):
            self.done = done
            self.total = total
            budgetRemaining = budget
            etaMinutes = eta
        case let .planState(planId, state, pause):
            if let pause {
                enterPaused(planId: planId, reason: pause)
            } else if state == .applying {
                phase = .running(planId: planId)
            } else {
                enterFinished(planId: planId, state: state)
            }
        case .item:
            break
        }
    }

    /// The store is the source of truth: the final `.planState` event can be lost when the event listener stops.
    private func settle(planId: String, returned state: PlanState) {
        if state != .applying {
            enterFinished(planId: planId, state: state)
        } else if let reason = (try? session.planStore.plan(id: planId))?.pauseReason {
            enterPaused(planId: planId, reason: reason)
            // The run stopped and waits for the owner: the only pause that goes to Slack (automatic waits do not).
            session.postSlack(SlackNotifier.applyPaused(workspace: session.config.name, reason: reason, done: done, total: total))
        } else {
            phase = .failed(planId: planId, message: "Apply stopped without a pause reason; reopen the workspace to recover the plan.")
        }
    }

    private func enterPaused(planId: String, reason: PauseReason) {
        guard phase != .paused(planId: planId, reason: reason) else { return }
        phase = .paused(planId: planId, reason: reason)
        notifier.applyPaused(workspace: session.config.name, reason: reason, done: done, total: total)
    }

    private func enterFinished(planId: String, state: PlanState) {
        guard phase != .finished(planId: planId, state: state) else { return }
        phase = .finished(planId: planId, state: state)
        notifier.applyFinished(workspace: session.config.name, state: state)
        session.postSlack(SlackNotifier.applyFinished(workspace: session.config.name, state: state, done: done, total: total))
    }

    private func runAction(_ action: @escaping @MainActor () async throws -> String) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let newPlanId = try await action()
                actionMessage = "New Draft \(newPlanId); review it and press Apply."
                await session.planning.reload()
                await session.planning.open(planId: newPlanId)
            } catch {
                actionMessage = "The action failed: \(error)"
            }
        }
    }

    private func refreshPlanScreen(_ planId: String) {
        Task {
            await session.planning.reload()
            await session.planning.open(planId: planId)
        }
    }

    private func handleWake() async {
        await session.recoverAfterWake()
    }
}
