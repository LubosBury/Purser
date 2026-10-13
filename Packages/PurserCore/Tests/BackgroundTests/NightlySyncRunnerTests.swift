import Foundation
import Testing
import GRDB
import Domain
import Store
import Catalog
@testable import Background

actor FakeSyncer: NightlyWorkspaceSyncer {
    private(set) var calls: [(workspace: UUID, appId: String)] = []
    private(set) var databases: [ObjectIdentifier] = []
    let failure: String?
    let newFindings: Int

    init(failure: String? = nil, newFindings: Int = 0) { self.failure = failure; self.newFindings = newFindings }

    func syncAndCheck(config: WorkspaceConfig, database: WorkspaceDatabase) async throws -> NightlySyncOutcome {
        calls.append((config.id, config.appId))
        databases.append(ObjectIdentifier(database))
        if let failure { throw URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: failure]) }
        return NightlySyncOutcome(syncId: 42, status: .complete, newFindingCount: newFindings)
    }
}

actor FakeNotifier: NightlyNotifier {
    private(set) var findings: [(String, Int)] = []
    private(set) var stale: [String] = []
    func notifyNewFindings(workspaceName: String, count: Int) async { findings.append((workspaceName, count)) }
    func notifyStaleSync(workspaceName: String, lastCompleteSync: Date?) async { stale.append(workspaceName) }
}

final class InMemoryLedger: NightlyLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [UUID: Date] = [:]
    private var notices: [UUID: Date] = [:]
    func lastAttempt(workspaceId: UUID) -> Date? { lock.withLock { attempts[workspaceId] } }
    func markAttempt(workspaceId: UUID, at date: Date) { lock.withLock { attempts[workspaceId] = date } }
    func lastStaleNotice(workspaceId: UUID) -> Date? { lock.withLock { notices[workspaceId] } }
    func markStaleNotice(workspaceId: UUID, at date: Date) { lock.withLock { notices[workspaceId] = date } }
}

@Suite struct NightlySyncRunnerTests {
    static func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    static let now = at("2030-03-02T03:30:00Z")

    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("purser-nightly-\(UUID().uuidString)", isDirectory: true)
    }

    /// One workspace with its config row, an optional finished sync and an optional Applying plan heartbeat.
    @discardableResult
    func makeWorkspace(root: URL, name: String, appId: String, hourUTC: Int, finishedAt: String?, status: String = "complete",
                       applyingHeartbeat: String? = nil) throws -> WorkspaceEntry {
        let registry = WorkspaceRegistry(root: root)
        let entry = try registry.create(name: name, colorHex: "#123456")
        let config = WorkspaceConfig(id: entry.id, name: name, colorHex: "#123456", isProduction: false, appId: appId,
                                     bundleId: "com.example.\(name.lowercased())", keyKind: .team, keyId: "KEY-\(name)",
                                     issuerId: "issuer", importMapping: nil, googleClientId: nil, slackWebhookEnabled: false,
                                     nightlySyncHourUTC: hourUTC)
        let database = try WorkspaceDatabase.open(at: registry.directory(for: entry))
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, config_json, updated_at) VALUES (?, ?, ?)",
                           arguments: [entry.id.uuidString, try JSONCoding.string(config), "2030-03-01T00:00:00Z"])
            if let finishedAt {
                try db.execute(sql: "INSERT INTO sync_run (trigger, status, started_at, finished_at) VALUES ('manual', ?, ?, ?)",
                               arguments: [status, finishedAt, finishedAt])
            }
            if let applyingHeartbeat {
                try db.execute(sql: """
                    INSERT INTO plan (id, origin, spec_json, binding_json, base_sync, state, plan_hash, verdict_hash, verdicts_json,
                                      excluded_json, confirmation_level, app_build, estimate_requests, estimate_minutes,
                                      created_at, updated_at, heartbeat_at)
                    VALUES ('plan-1', 'PROMO', '{}', '{}', 1, 'applying', 'h', 'v', '[]', '[]', 0, 'test', 1, 1, ?, ?, ?)
                    """, arguments: [applyingHeartbeat, applyingHeartbeat, applyingHeartbeat])
            }
        }
        return entry
    }

    func runner(root: URL, syncer: FakeSyncer, notifier: FakeNotifier, ledger: InMemoryLedger, now: Date) -> NightlySyncRunner {
        NightlySyncRunner(root: root, syncer: syncer, notifier: notifier, ledger: ledger, now: { now })
    }

    @Test func dueWorkspacesAreSyncedSeparatelyAndFindingsNotified() async throws {
        let root = tempRoot()
        let alpha = try makeWorkspace(root: root, name: "Alpha", appId: "1000000001", hourUTC: 3, finishedAt: "2030-03-01T03:10:00Z")
        let beta = try makeWorkspace(root: root, name: "Beta", appId: "1000000002", hourUTC: 2, finishedAt: "2030-03-01T02:10:00Z")
        let syncer = FakeSyncer(newFindings: 2)
        let notifier = FakeNotifier()
        let ledger = InMemoryLedger()
        let reports = await runner(root: root, syncer: syncer, notifier: notifier, ledger: ledger, now: Self.now).runOnce()
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { if case .synced = $0.outcome { return true } else { return false } })
        let calls = await syncer.calls
        #expect(Set(calls.map { $0.workspace }) == [alpha.id, beta.id])
        #expect(calls.first { $0.workspace == alpha.id }?.appId == "1000000001")
        #expect(calls.first { $0.workspace == beta.id }?.appId == "1000000002")
        let notified = await notifier.findings
        #expect(notified.map { $0.0 }.sorted() == ["Alpha", "Beta"])
        #expect(ledger.lastAttempt(workspaceId: alpha.id) == Self.now)
        #expect(Set(reports.compactMap(\.hourUTC)) == [2, 3])
    }

    @Test func workspaceSyncedAfterTheSlotIsNotDue() async throws {
        let root = tempRoot()
        try makeWorkspace(root: root, name: "Alpha", appId: "1000000001", hourUTC: 3, finishedAt: "2030-03-02T03:05:00Z")
        let syncer = FakeSyncer()
        let reports = await runner(root: root, syncer: syncer, notifier: FakeNotifier(), ledger: InMemoryLedger(), now: Self.now).runOnce()
        #expect(reports.first?.outcome == .notDue)
        #expect(await syncer.calls.isEmpty)
    }

    @Test func workspaceWithRunningApplyIsSkipped() async throws {
        let root = tempRoot()
        try makeWorkspace(root: root, name: "Alpha", appId: "1000000001", hourUTC: 3, finishedAt: "2030-03-01T03:05:00Z",
                          applyingHeartbeat: "2030-03-02T03:29:50Z")
        let syncer = FakeSyncer()
        let reports = await runner(root: root, syncer: syncer, notifier: FakeNotifier(), ledger: InMemoryLedger(), now: Self.now).runOnce()
        #expect(reports.first?.outcome == .skippedApplying)
        #expect(await syncer.calls.isEmpty)
    }

    @Test func failingSyncNotifiesStalenessOncePerDayAndRetriesAfterAnHour() async throws {
        let root = tempRoot()
        let alpha = try makeWorkspace(root: root, name: "Alpha", appId: "1000000001", hourUTC: 3, finishedAt: "2030-02-28T03:00:00Z")
        let syncer = FakeSyncer(failure: "offline")
        let notifier = FakeNotifier()
        let ledger = InMemoryLedger()
        let first = await runner(root: root, syncer: syncer, notifier: notifier, ledger: ledger, now: Self.now).runOnce()
        guard case .failed = first.first?.outcome else { Issue.record("expected failed, got \(String(describing: first.first?.outcome))"); return }
        #expect(first.first?.staleNotified == true)
        #expect(await notifier.findings.isEmpty)

        let tenMinutesLater = Self.now.addingTimeInterval(600)
        let second = await runner(root: root, syncer: syncer, notifier: notifier, ledger: ledger, now: tenMinutesLater).runOnce()
        #expect(second.first?.outcome == .notDue)
        #expect(second.first?.staleNotified == false)

        let twoHoursLater = Self.now.addingTimeInterval(7200)
        let third = await runner(root: root, syncer: syncer, notifier: notifier, ledger: ledger, now: twoHoursLater).runOnce()
        guard case .failed = third.first?.outcome else { Issue.record("expected retry"); return }
        #expect(await syncer.calls.count == 2)
        #expect(await notifier.stale == ["Alpha"])
        #expect(ledger.lastStaleNotice(workspaceId: alpha.id) == Self.now)
    }

    @Test func partialSyncCountsAsDoneForTheNightButNotAsFresh() async throws {
        let root = tempRoot()
        try makeWorkspace(root: root, name: "Alpha", appId: "1000000001", hourUTC: 3, finishedAt: "2030-03-02T03:10:00Z", status: "partial")
        let notifier = FakeNotifier()
        let reports = await runner(root: root, syncer: FakeSyncer(), notifier: notifier, ledger: InMemoryLedger(), now: Self.now).runOnce()
        #expect(reports.first?.outcome == .notDue)
        #expect(await notifier.stale == ["Alpha"])
    }

    /// The in-app fallback reuses the DatabasePool of the workspace the app has open (no second pool on the file).
    @Test func databaseRegisteredByTheAppIsReused() async throws {
        let root = tempRoot()
        let entry = try makeWorkspace(root: root, name: "Alpha", appId: "1000000001", hourUTC: 3, finishedAt: "2030-03-01T03:10:00Z")
        let directory = WorkspaceRegistry(root: root).directory(for: entry)
        let open = try WorkspaceDatabase.open(at: directory)
        OpenWorkspaceDatabases.shared.register(open, directory: directory)
        defer { OpenWorkspaceDatabases.shared.unregister(directory: directory) }
        let syncer = FakeSyncer()
        _ = await runner(root: root, syncer: syncer, notifier: FakeNotifier(), ledger: InMemoryLedger(), now: Self.now).runOnce()
        #expect(await syncer.databases == [ObjectIdentifier(open)])
    }
}
