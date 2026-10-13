import AppKit
import Foundation
import Observation
import ASCClient
import Audit
import Background
import Catalog
import Domain
import Executor
import Planner
import Policy
import PurserSecurity
import Store

enum SessionError: Error, CustomStringConvertible {
    case missingConfig
    case foreignDatabase
    case immutableField

    var description: String {
        switch self {
        case .missingConfig: return "The workspace database has no configuration."
        case .foreignDatabase: return "The database belongs to another workspace."
        case .immutableField: return "The App ID and bundle ID of an existing workspace cannot be changed; create a new workspace."
        }
    }
}

/// One open workspace: its database, audit, read-only ASC client, sync and catalog (K11). M0 has no writer,
/// and the session never holds a write client (M2 builds one per apply in WorkspaceSession+Apply.swift).
@Observable @MainActor
final class WorkspaceSession {
    // K11, M0 members (names and types are binding for M1-M5).
    let entry: WorkspaceEntry
    private(set) var config: WorkspaceConfig
    let database: WorkspaceDatabase
    let audit: AuditLog
    let catalogStore: CatalogStore
    let planStore: PlanStore
    /// The app version stored with plans (K2 `app_build`).
    let appBuild: String
    // M1 (K11): Google account of this workspace; the token lives only in this workspace's Keychain item.
    let google: GoogleAccount
    /// M1 (K11): invariants after every sync; rebuilt by saveConfig(_:) so I5 uses the current nominal discounts.
    private(set) var postSyncChecks: PostSyncChecks
    /// M1 (K11): Planner(policy: PolicyEngine(invariants: PolicyEngine.invariants(for: config))); rebuilt by saveConfig(_:).
    private(set) var planner: Planner
    /// M1 (K11): PlanPersistence(store: planStore, audit: audit, appBuild: appBuild).
    let persistence: PlanPersistence
    /// M1 (K11): planning screens; uses this session's planner, planStore and persistence.
    let planning: PlanningModel
    /// The Keychain of this Mac (KeychainSecretStore); accounts are per workspace (SecretAccount).
    let secretStore: any SecretStore
    /// One RateBudget per workspace for reads and writes (the hourly ASC budget is per key).
    let budget: RateBudget
    /// One AppGuard per workspace, shared by the read client and every write client; rebuilt with the read stack
    /// when config.appId changes.
    private(set) var appGuard: AppGuard
    /// LiveASCClient over ASCHTTPClient(readOnly: true). nil while syncBlockedReason != nil (no key).
    private(set) var readClient: LiveASCClient?
    private(set) var syncEngine: SyncEngine?              // nil exactly when readClient is nil
    /// Why sync is unavailable (missing key); nil when it can run.
    private(set) var syncBlockedReason: String?
    private(set) var snapshot: CatalogSnapshot?
    private(set) var findings: [FindingRecord] = []
    private(set) var isSyncing = false
    private(set) var lastSync: SyncResult?
    private(set) var rateLimit: RateLimitSnapshot?        // budget.latest after the last request

    // Internal UI state (allowed by K11 in addition to the binding members).
    private(set) var syncRequestCount = 0
    private(set) var isClosed = false
    var errorMessage: String?

    // MARK: M2 (K11)

    /// Executor whose writer is readClient (every write fails with ASCError.readOnlyClient); serves pause, abort,
    /// recover and reconcileAfterSync when no apply runs. nil exactly when readClient is nil.
    private(set) var readExecutor: Executor?
    /// The write-capable Executor of the apply/resume in progress; set and cleared only by WorkspaceSession+Apply.
    var activeExecutor: Executor?
    /// Bumped after recover, abort, reconcile and plan actions so the paused-plan banner and History reload.
    var applyRevision = 0
    /// Touch ID of this Mac (AppEnvironment.gate) for every Executor and probe of the session.
    var biometricGate: any BiometricGate { environment.gate }

    /// The session owns its ApplyController (one per session); WorkspaceApplyHost only displays it.
    @ObservationIgnored private var storedApplyController: ApplyController?
    var applyController: ApplyController {
        if let controller = storedApplyController { return controller }
        let controller = ApplyController(session: self)
        storedApplyController = controller
        return controller
    }

    /// Observers of syncs made by another process or by the in-app fallback (M4).
    private var reconcileObservers: [any NSObjectProtocol] = []

    /// After a sync made by the login item or the in-app fallback: Scheduled -> Effective, late verification and
    /// Superseded marking (K10 reconcileAfterSync), then the catalog and the plan lists reload.
    func reconcileLatest() async {
        guard let executor = activeExecutor ?? readExecutor else { return }
        // The snapshot decodes every live observation and price point: load it off the main actor.
        let store = catalogStore
        guard let snapshot = await Task.detached(priority: .utility, operation: { try? store.latestSnapshot() }).value else { return }
        try? await executor.reconcileAfterSync(snapshot)
        await reloadCatalog()
        await planning.reload()
    }

    private let environment: AppEnvironment
    private let configStore: WorkspaceConfigStore
    /// The app id `appGuard` was built for.
    private var guardAppId: String

    private init(entry: WorkspaceEntry, database: WorkspaceDatabase, config: WorkspaceConfig, environment: AppEnvironment,
                 owner: AuditActor) throws {
        self.entry = entry
        self.database = database
        self.config = config
        self.environment = environment
        self.audit = AuditLogFactory.make(database: database, owner: owner)
        self.catalogStore = CatalogStore(database: database)
        self.planStore = PlanStore(database: database)
        self.appBuild = AppBuild.version
        self.secretStore = environment.secretStore
        self.budget = RateBudget(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
        self.appGuard = AppGuard(appId: config.appId)
        self.guardAppId = config.appId
        self.configStore = WorkspaceConfigStore(database: database)
        // M1: reads only the init parameter `config` and stored `let` properties assigned above (never self.config).
        let tokenAccount = SecretAccount.googleToken(config.id)
        google = GoogleAccount(
            transport: URLSessionTransport(),
            loadToken: { [secretStore] in try secretStore.get(account: tokenAccount) },
            saveToken: { [secretStore] data in try secretStore.set(data, account: tokenAccount) })
        postSyncChecks = WorkspaceSession.makePostSyncChecks(config: config, catalogStore: catalogStore,
                                                             database: database, audit: audit)
        // M1 (K11): reads only the init parameter `config` and stored `let` properties (budget, planStore, audit, ...).
        let planner = Planner(policy: PolicyEngine(invariants: PolicyEngine.invariants(for: config)))
        let persistence = PlanPersistence(store: planStore, audit: audit, appBuild: appBuild)
        self.planner = planner
        self.persistence = persistence
        planning = try PlanningModel(
            deps: PlanningModel.Dependencies(audit: audit, catalog: catalogStore, store: planStore, persistence: persistence,
                                             rateLimit: { [budget] in await budget.latest }),
            config: config, planner: planner, google: google)
        planning.saveImportMapping = { [weak self] mapping in
            guard let self else { return }
            var updated = self.config
            updated.importMapping = mapping
            try self.saveConfig(updated)
        }
        OpenWorkspaceDatabases.shared.register(database, directory: WorkspaceRegistry(root: AppPaths.workspaces.root).directory(for: entry))
        let center = NotificationCenter.default
        for name in [Notification.Name.purserNightlySyncFinished, NSApplication.didBecomeActiveNotification] {
            reconcileObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.reconcileLatest() }
            })
        }
        Task { [weak self] in await self?.reconcileLatest() }
    }

    /// K8: every PolicyEngine of the session is built with the invariants of the current config.
    private static func makePostSyncChecks(config: WorkspaceConfig, catalogStore: CatalogStore, database: WorkspaceDatabase,
                                           audit: AuditLog) -> PostSyncChecks {
        PostSyncChecks(
            runner: InvariantRunner(engine: PolicyEngine(invariants: PolicyEngine.invariants(for: config)),
                                    catalog: catalogStore, database: database, audit: audit),
            catalog: catalogStore, now: { Date() })
    }

    static func open(entry: WorkspaceEntry, registry: WorkspaceRegistry, environment: AppEnvironment, owner: AuditActor,
                     logSignIn: Bool) throws -> WorkspaceSession {
        let database = try WorkspaceDatabase.open(at: registry.directory(for: entry))
        guard let config = try WorkspaceConfigStore(database: database).load() else { throw SessionError.missingConfig }
        guard config.id == entry.id else { throw SessionError.foreignDatabase }
        let session = try WorkspaceSession(entry: entry, database: database, config: config, environment: environment,
                                       owner: owner)
        if logSignIn {
            try session.audit.append(.signIn, refs: [:], payload: SessionOpenedPayload(workspaceName: config.name, appVersion: AppBuild.version))
        }
        try session.audit.append(.workspaceOpened, refs: ["workspace": entry.id.uuidString],
                                 payload: SessionOpenedPayload(workspaceName: config.name, appVersion: AppBuild.version))
        session.rebuildClients()
        return session
    }

    /// Read-only ASC stack: GET-scoped tokens, the workspace AppGuard, pacing by the workspace RateBudget.
    /// The key is read from the Keychain only here and lives on only inside the JWTSigner.
    private func rebuildClients() {
        readClient = nil
        syncEngine = nil
        readExecutor = nil
        planning.equalizer = nil
        if guardAppId != config.appId {
            appGuard = AppGuard(appId: config.appId)
            guardAppId = config.appId
        }
        do {
            guard let keyData = try secretStore.get(account: SecretAccount.ascPrivateKey(config.id)) else {
                syncBlockedReason = "The Keychain has no .p8 key for this workspace. Import it in Settings."
                return
            }
            let identity: JWTIdentity = config.keyKind == .team ? .team(issuerId: config.issuerId ?? "") : .individual
            let signer = try JWTSigner(keyId: config.keyId, identity: identity, privateKeyPEM: String(decoding: keyData, as: UTF8.self))
            let http = ASCHTTPClient(transport: URLSessionTransport(), signer: signer, budget: budget,
                                     appGuard: appGuard, readOnly: true, now: { Date() })
            let reader = LiveASCClient(http: http)
            readClient = reader
            planning.equalizer = { [reader] subscriptionId, pricePointId, planType in
                try await reader.equalizations(subscriptionId: subscriptionId, pricePointId: pricePointId, planType: planType)
            }
            syncEngine = SyncEngine(database: database, reader: reader, audit: audit, config: config, now: { Date() })
            syncBlockedReason = nil
            if let readClient, let syncEngine {
                readExecutor = Executor(database: database, config: config, reader: readClient, writer: readClient, sync: syncEngine,
                                        catalog: catalogStore, policy: PolicyEngine(invariants: PolicyEngine.invariants(for: config)),
                                        audit: audit, gate: environment.gate, budget: budget, now: { Date() },
                                        sleep: { try await Task.sleep(for: $0) })
            }
            scheduleLaunchRecovery()
        } catch {
            syncBlockedReason = "The key cannot be used: \(error)"
        }
    }

    func close() {
        for observer in reconcileObservers { NotificationCenter.default.removeObserver(observer) }
        reconcileObservers = []
        OpenWorkspaceDatabases.shared.unregister(directory: WorkspaceRegistry(root: AppPaths.workspaces.root).directory(for: entry))
        isClosed = true
        readClient = nil
        syncEngine = nil
        storedApplyController?.shutdown()
        storedApplyController = nil
        readExecutor = nil
        activeExecutor = nil
    }

    func reloadCatalog() async {
        let store = catalogStore
        do {
            let (snapshot, findings) = try await Task.detached(priority: .userInitiated) {
                (try store.latestSnapshot(), try store.findings(includeAcked: false))
            }.value
            self.snapshot = snapshot
            self.findings = findings
            // The guard learns products only from a sync in this process. The stored snapshot was read under this
            // workspace's app (its app id never changes), so its products are allowed too, as in LiveNightly.
            if let snapshot {
                await appGuard.allowProducts(Set(snapshot.subscriptions.keys).union(snapshot.iaps.keys))
            }
        } catch {
            errorMessage = "The catalog cannot be loaded: \(error)"
        }
    }

    func syncNow() async {
        guard !isClosed, !isSyncing, let syncEngine, let readClient else { return }
        isSyncing = true
        errorMessage = nil
        let base = await readClient.currentRequestCount()
        syncRequestCount = 0
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                let count = await readClient.currentRequestCount()
                self?.syncRequestCount = count - base
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer {
            poll.cancel()
            isSyncing = false
        }
        do {
            let result = try await syncEngine.sync(trigger: .manual, scope: .all)
            lastSync = result
            let invariantFindings = await runPostSyncChecks(status: result.status)
            await afterSyncForPlans(result, invariantFindings: invariantFindings)
            syncRequestCount = lastSync?.requestCount ?? syncRequestCount
            rateLimit = await budget.latest
        } catch {
            errorMessage = "Sync failed: \(error)"
        }
        await reloadCatalog()
    }

    /// M1 (K11): INVARIANT findings after every sync, off the main actor.
    private func runPostSyncChecks(status: SyncStatus) async -> [FindingRecord] {
        let checks = postSyncChecks
        var raised: [FindingRecord] = []
        do {
            raised = try await Task.detached(priority: .userInitiated) { try checks.afterSync(status: status) }.value
        } catch {
            errorMessage = "The invariant check after the sync failed: \(error)"
        }
        await planning.reload()
        return raised
    }

    func history(for cell: CellKey) -> [ObservationRecord] {
        (try? catalogStore.history(cell: cell)) ?? []
    }

    func liveObservations(productAscId: String) -> [ObservationRecord] {
        (try? catalogStore.liveObservations(productAscId: productAscId)) ?? []
    }

    // MARK: - Settings

    /// Saves a changed config and logs configChanged in the same transaction. App id and bundle id are immutable (D3).
    func saveConfig(_ updated: WorkspaceConfig) throws {
        guard updated.id == config.id, updated.appId == config.appId, updated.bundleId == config.bundleId else {
            throw SessionError.immutableField
        }
        let before = config
        try database.writer.write { db in
            try configStore.save(updated, at: Date(), in: db)
            try audit.append(.configChanged, refs: ["workspace": updated.id.uuidString],
                             payload: ConfigChangePayload(action: "updated", before: before, after: updated), in: db)
        }
        config = updated
        postSyncChecks = WorkspaceSession.makePostSyncChecks(config: updated, catalogStore: catalogStore,
                                                             database: database, audit: audit)
        planner = Planner(policy: PolicyEngine(invariants: PolicyEngine.invariants(for: updated)))
        planning.update(config: updated, planner: planner)
        rebuildClients()
    }

    /// Replaces the workspace key after Touch ID. The PEM goes only to the Keychain; the audit gets kind and key id.
    func replaceKey(keyKind: KeyKind, keyId: String, issuerId: String?, pem: String) async throws {
        let identity: JWTIdentity = keyKind == .team ? .team(issuerId: issuerId ?? "") : .individual
        _ = try JWTSigner(keyId: keyId, identity: identity, privateKeyPEM: pem)
        try await environment.gate.authenticate(reason: "save the new key of the workspace \(config.name)")
        try secretStore.set(Data(pem.utf8), account: SecretAccount.ascPrivateKey(config.id))
        try audit.append(.configChanged, refs: ["workspace": config.id.uuidString],
                         payload: KeyImportedPayload(keyKind: keyKind.rawValue, keyId: keyId))
        var updated = config
        updated.keyKind = keyKind
        updated.keyId = keyId
        updated.issuerId = keyKind == .team ? issuerId : nil
        try saveConfig(updated)
    }
}
