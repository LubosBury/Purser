import Foundation
import OSLog
import Domain
import Store
import Catalog
import PurserSecurity
import ASCClient
import Policy
import Planner
import Executor

enum WorkspaceSessionError: Error, LocalizedError {
    case missingKey
    case syncUnavailable
    case applyInProgress

    var errorDescription: String? {
        switch self {
        case .missingKey: return "The App Store Connect key for this workspace is not in the Keychain."
        case .syncUnavailable: return "The read-only App Store Connect client is not available (missing key or offline)."
        case .applyInProgress: return "Another apply or resume is running in this workspace."
        }
    }
}

/// When this process started (touched by AppDelegate at launch). Launch recovery pauses only plans whose heartbeat is older.
enum ProcessLaunch {
    static let date = Date()
}

extension WorkspaceSession {
    /// Workspaces whose launch recovery already ran in this process.
    private static var launchRecovered: Set<UUID> = []

    // MARK: Apply, resume, pause, abort (K11)

    /// Apply with a write-capable client that exists only for this call (spec §4: write token only after Touch ID).
    func apply(planId: String, confirm: @escaping @Sendable (ConfirmationRequest) async -> ConfirmationResponse,
               onEvent: @escaping @MainActor (ExecutorEvent) -> Void) async throws -> PlanState {
        try await withWriteExecutor(onEvent: onEvent) { try await $0.apply(planId: planId, confirm: confirm) }
    }

    func resume(planId: String, confirm: @escaping @Sendable (ConfirmationRequest) async -> ConfirmationResponse,
                onEvent: @escaping @MainActor (ExecutorEvent) -> Void) async throws -> PlanState {
        try await withWriteExecutor(onEvent: onEvent) { try await $0.resume(planId: planId, confirm: confirm) }
    }

    func pause(planId: String, reason: PauseReason) async {
        await (activeExecutor ?? readExecutor)?.pause(planId: planId, reason: reason)
    }

    func abort(planId: String) async throws -> PlanState {
        guard let executor = activeExecutor ?? readExecutor else { throw WorkspaceSessionError.missingKey }
        defer { applyRevision += 1 }
        return try await executor.abort(planId: planId)
    }

    // MARK: Plan actions without writes (spec §6 PartiallyApplied, §8 "Roll back")

    /// A WITHDRAW Draft for the written future-dated items of a Scheduled or PartiallyApplied plan; nothing is written here.
    func withdrawWritten(planId: String) async throws -> String {
        guard let executor = activeExecutor ?? readExecutor else { throw WorkspaceSessionError.syncUnavailable }
        defer { applyRevision += 1 }
        return try await executor.withdrawWritten(planId: planId, planner: planner)
    }

    /// "Replan the rest" from the stored spec (an import plan re-plans its stored table).
    func replanRest(planId: String) async throws -> String {
        guard let executor = activeExecutor ?? readExecutor else { throw WorkspaceSessionError.syncUnavailable }
        defer { applyRevision += 1 }
        return try await executor.replanRest(planId: planId, planner: planner, freshTable: nil)
    }

    /// "Close" with a mandatory reason (stored in the audit).
    func closePlan(planId: String, reason: String) async throws {
        guard let executor = activeExecutor ?? readExecutor else { throw WorkspaceSessionError.syncUnavailable }
        defer { applyRevision += 1 }
        try await executor.close(planId: planId, reason: reason)
    }

    // MARK: Recovery

    /// Launch recovery: once per workspace and process, as soon as the read stack exists (called from rebuildClients()).
    func scheduleLaunchRecovery() {
        guard readExecutor != nil, Self.launchRecovered.insert(config.id).inserted else { return }
        Task { await recoverAfterLaunch() }
    }

    private func recoverAfterLaunch() async {
        guard let executor = activeExecutor ?? readExecutor else { return }
        do {
            _ = try await executor.recover(afterWake: false, launchedAt: ProcessLaunch.date)
        } catch {
            errorMessage = "Recovering plans after launch failed: \(error)"
        }
        applyRevision += 1
    }

    /// After the Mac wakes: a plan running in the write executor stops with SLEEP at the next item; stale plans become Paused(SLEEP).
    func recoverAfterWake() async {
        guard let executor = activeExecutor ?? readExecutor else { return }
        _ = try? await executor.recover(afterWake: true)
        applyRevision += 1
    }

    // MARK: After every sync (M1 CR-10 hook in syncNow)

    /// Scheduled -> Effective, late verification, Superseded/Withdrawn (K10), then the Slack notice about new findings.
    func afterSyncForPlans(_ result: SyncResult, invariantFindings: [FindingRecord]) async {
        if result.status != .failed, let executor = activeExecutor ?? readExecutor {
            do {
                // The snapshot decodes every live observation and price point: load it off the main actor.
                let store = catalogStore
                if let snapshot = try await Task.detached(priority: .userInitiated, operation: { try store.latestSnapshot() }).value {
                    try await executor.reconcileAfterSync(snapshot)
                }
            } catch {
                errorMessage = "Evaluating plans after the sync failed: \(error)"
            }
            applyRevision += 1
        }
        let fresh = result.newFindings + invariantFindings
        if !fresh.isEmpty { postSlack(SlackNotifier.newFindings(workspace: config.name, findings: fresh)) }
    }

    // MARK: Slack (spec §4)

    /// The workspace webhook when Slack is enabled and a valid webhook is in the Keychain.
    func slackWebhookURL() -> URL? {
        guard config.slackWebhookEnabled,
              let data = try? secretStore.get(account: SecretAccount.slackWebhook(config.id)),
              let url = URL(string: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              SlackWebhook.isValid(url) else { return nil }
        return url
    }

    /// Fire-and-forget Slack message; failures are logged privately (the error text may contain the webhook URL).
    func postSlack(_ text: String) {
        guard let url = slackWebhookURL() else { return }
        Task.detached(priority: .utility) {
            do {
                try await SlackNotifier(transport: URLSessionTransport()).publish(text: text, webhook: url)
            } catch {
                Logger(subsystem: "com.lubosbury.purser", category: "slack")
                    .error("Slack notification failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Stores (valid https://hooks.slack.com/... only) or removes the webhook in the Keychain. The audit gets "set"/"removed",
    /// never the URL.
    func saveSlackWebhook(_ text: String?) throws {
        let account = SecretAccount.slackWebhook(config.id)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try secretStore.delete(account: account)
            try audit.append(.configChanged, refs: ["workspace": config.id.uuidString], payload: ["slackWebhook": "removed"])
            return
        }
        guard let url = URL(string: trimmed), SlackWebhook.isValid(url) else { throw SlackPublishError.invalidWebhook }
        try secretStore.set(Data(trimmed.utf8), account: account)
        try audit.append(.configChanged, refs: ["workspace": config.id.uuidString], payload: ["slackWebhook": "set"])
    }

    // MARK: The write-capable executor

    private func withWriteExecutor(onEvent: @escaping @MainActor (ExecutorEvent) -> Void,
                                   _ body: (Executor) async throws -> PlanState) async throws -> PlanState {
        guard activeExecutor == nil else { throw WorkspaceSessionError.applyInProgress }
        let executor = try await makeWriteExecutor()
        guard activeExecutor == nil else { throw WorkspaceSessionError.applyInProgress }
        activeExecutor = executor
        let listener = Task { @MainActor in
            for await event in executor.events { onEvent(event) }
        }
        defer {
            listener.cancel()
            activeExecutor = nil
            applyRevision += 1
        }
        return try await body(executor)
    }

    /// The only place in the app that builds a write-capable ASC client for plans (architecture test, Task 2.10).
    private func makeWriteExecutor() async throws -> Executor {
        guard let readClient, let syncEngine else { throw WorkspaceSessionError.syncUnavailable }
        guard let pem = try secretStore.get(account: SecretAccount.ascPrivateKey(config.id)) else { throw WorkspaceSessionError.missingKey }
        let identity: JWTIdentity = config.keyKind == .team ? .team(issuerId: config.issuerId ?? "") : .individual
        let signer = try JWTSigner(keyId: config.keyId, identity: identity, privateKeyPEM: String(decoding: pem, as: UTF8.self))
        let http = ASCHTTPClient(transport: Self.writeTransport(), signer: signer, budget: budget, appGuard: appGuard,
                                 readOnly: false, now: { Date() })
        let executor = Executor(database: database, config: config, reader: readClient, writer: LiveASCClient(http: http),
                                sync: syncEngine, catalog: catalogStore,
                                policy: PolicyEngine(invariants: PolicyEngine.invariants(for: config)), audit: audit,
                                gate: biometricGate, budget: budget, now: { Date() }, sleep: { try await Task.sleep(for: $0) })
        #if DEBUG
        await DrillSupport.install(on: executor)
        #endif
        return executor
    }

    // MARK: Product creation

    /// A ProductCreator with its own write-capable client for one run of the "New products" sheet. The session never
    /// stores it; the key is read from the Keychain now and the creator asks for Touch ID before it writes.
    func makeProductCreator() throws -> ProductCreator {
        guard activeExecutor == nil else { throw WorkspaceSessionError.applyInProgress }
        guard let readClient else { throw WorkspaceSessionError.syncUnavailable }
        guard let pem = try secretStore.get(account: SecretAccount.ascPrivateKey(config.id)) else { throw WorkspaceSessionError.missingKey }
        let identity: JWTIdentity = config.keyKind == .team ? .team(issuerId: config.issuerId ?? "") : .individual
        let signer = try JWTSigner(keyId: config.keyId, identity: identity, privateKeyPEM: String(decoding: pem, as: UTF8.self))
        let http = ASCHTTPClient(transport: URLSessionTransport(), signer: signer, budget: budget, appGuard: appGuard,
                                 readOnly: false, now: { Date() })
        return ProductCreator(config: config, http: http, reader: readClient, audit: audit, budget: budget, gate: biometricGate)
    }

    private static func writeTransport() -> any HTTPTransport {
        #if DEBUG
        return DrillSupport.wrap(URLSessionTransport())
        #else
        return URLSessionTransport()
        #endif
    }
}
