import Foundation
import UserNotifications
import Domain
import Store
import Audit
import PurserSecurity
import ASCClient
import Catalog
import Policy

public enum NightlySyncError: Error, Equatable {
    case missingKey, invalidKeyEncoding, missingIssuer
}

/// The production syncer: read-only ASC client with GET-scoped tokens (T3-35), SyncEngine(trigger: .nightly),
/// then InvariantRunner. It never constructs anything that can write to ASC.
public struct LiveNightlyWorkspaceSyncer: NightlyWorkspaceSyncer {
    let secrets: any SecretStore
    let transport: any HTTPTransport
    let auditActor: String
    let now: @Sendable () -> Date

    public init(secrets: any SecretStore, transport: any HTTPTransport = URLSessionTransport(), auditActor: String,
                now: @escaping @Sendable () -> Date) {
        self.secrets = secrets; self.transport = transport; self.auditActor = auditActor; self.now = now
    }

    public func syncAndCheck(config: WorkspaceConfig, database: WorkspaceDatabase) async throws -> NightlySyncOutcome {
        guard let keyData = try secrets.get(account: SecretAccount.ascPrivateKey(config.id)) else { throw NightlySyncError.missingKey }
        guard let pem = String(data: keyData, encoding: .utf8) else { throw NightlySyncError.invalidKeyEncoding }
        let identity: JWTIdentity
        switch config.keyKind {
        case .team:
            guard let issuer = config.issuerId else { throw NightlySyncError.missingIssuer }
            identity = .team(issuerId: issuer)
        case .individual:
            identity = .individual
        }
        let signer = try JWTSigner(keyId: config.keyId, identity: identity, privateKeyPEM: pem)
        let budget = RateBudget(now: now, sleep: { try await Task.sleep(for: $0) })
        let appGuard = AppGuard(appId: config.appId)
        let catalog = CatalogStore(database: database)
        if let previous = try catalog.latestSnapshot() {
            await appGuard.allowProducts(Set(previous.subscriptions.keys).union(previous.iaps.keys))
        }
        let http = ASCHTTPClient(transport: transport, signer: signer, budget: budget, appGuard: appGuard, readOnly: true, now: now)
        let actorName = auditActor
        let audit = AuditLog(database: database, actor: { actorName }, now: now)
        let engine = SyncEngine(database: database, reader: LiveASCClient(http: http), audit: audit, config: config, now: now)
        let result = try await engine.sync(trigger: .nightly, scope: .all)
        var newFindings = result.newFindings.count
        if result.status != .failed, let snapshot = try catalog.latestSnapshot() {
            // K8: the same invariants as the app (I5 with the workspace's nominal discounts).
            let invariants = InvariantRunner(engine: PolicyEngine(invariants: PolicyEngine.invariants(for: config)),
                                             catalog: catalog, database: database, audit: audit)
            newFindings += try invariants.run(snapshot: snapshot, today: CalendarDate.today(now: now()))
                .filter { $0.firstSync == snapshot.syncId }
                .count
        }
        return NightlySyncOutcome(syncId: result.syncId, status: result.status, newFindingCount: newFindings)
    }
}

/// Ledger in the App Group defaults suite, so the app fallback and the login item see the same attempts.
public struct UserDefaultsNightlyLedger: NightlyLedger {
    let suiteName: String?

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    public func lastAttempt(workspaceId: UUID) -> Date? { defaults.object(forKey: "nightly.attempt.\(workspaceId.uuidString)") as? Date }
    public func markAttempt(workspaceId: UUID, at: Date) { defaults.set(at, forKey: "nightly.attempt.\(workspaceId.uuidString)") }
    public func lastStaleNotice(workspaceId: UUID) -> Date? { defaults.object(forKey: "nightly.stale.\(workspaceId.uuidString)") as? Date }
    public func markStaleNotice(workspaceId: UUID, at: Date) { defaults.set(at, forKey: "nightly.stale.\(workspaceId.uuidString)") }
}

/// macOS notifications: counts only, never prices or identifiers beyond the workspace name.
public struct UserNotificationNightlyNotifier: NightlyNotifier {
    public init() {}

    public static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func notifyNewFindings(workspaceName: String, count: Int) async {
        let noun = count == 1 ? "new finding" : "new findings"
        await post(id: "findings.\(workspaceName)", title: "Purser · \(workspaceName)",
                   body: "The nightly sync found \(count) \(noun). Open Findings.")
    }

    public func notifyStaleSync(workspaceName: String, lastCompleteSync: Date?) async {
        let when = lastCompleteSync.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        await post(id: "stale.\(workspaceName)", title: "Purser · \(workspaceName)",
                   body: "The last full sync is older than 36 h (last at \(when)).")
    }

    private func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

extension NightlySyncRunner {
    /// The runner used by both the login item and the in-app fallback.
    public static func live(root: URL, keychainAccessGroup: String?, ledgerSuite: String?, auditActor: String) -> NightlySyncRunner {
        NightlySyncRunner(root: root,
                          syncer: LiveNightlyWorkspaceSyncer(secrets: KeychainSecretStore(accessGroup: keychainAccessGroup),
                                                             auditActor: auditActor, now: { Date() }),
                          notifier: UserNotificationNightlyNotifier(),
                          ledger: UserDefaultsNightlyLedger(suiteName: ledgerSuite),
                          now: { Date() })
    }
}
