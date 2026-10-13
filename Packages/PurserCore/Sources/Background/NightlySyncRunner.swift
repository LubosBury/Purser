import Foundation
import Domain
import Store
import Catalog

public struct NightlySyncOutcome: Hashable, Sendable {
    public var syncId: Int64
    public var status: SyncStatus
    public var newFindingCount: Int
    public init(syncId: Int64, status: SyncStatus, newFindingCount: Int) {
        self.syncId = syncId; self.status = status; self.newFindingCount = newFindingCount
    }
}

/// Read-only sync of one workspace plus invariants (never writes to ASC).
public protocol NightlyWorkspaceSyncer: Sendable {
    func syncAndCheck(config: WorkspaceConfig, database: WorkspaceDatabase) async throws -> NightlySyncOutcome
}

public protocol NightlyNotifier: Sendable {
    func notifyNewFindings(workspaceName: String, count: Int) async
    func notifyStaleSync(workspaceName: String, lastCompleteSync: Date?) async
}

/// Per-workspace attempt and notice times; lives in the App Group defaults, shared by app and login item.
public protocol NightlyLedger: Sendable {
    func lastAttempt(workspaceId: UUID) -> Date?
    func markAttempt(workspaceId: UUID, at: Date)
    func lastStaleNotice(workspaceId: UUID) -> Date?
    func markStaleNotice(workspaceId: UUID, at: Date)
}

public enum NightlyWorkspaceOutcome: Hashable, Sendable {
    case notDue
    case skippedApplying
    case synced(NightlySyncOutcome)
    case failed(String)
    case unreadable(String)
}

public struct NightlyWorkspaceReport: Hashable, Sendable {
    public var workspaceId: UUID
    public var name: String
    public var hourUTC: Int?
    public var outcome: NightlyWorkspaceOutcome
    public var staleNotified: Bool
}

/// One pass over all workspaces. Each workspace is opened, decided, synced and released on its own,
/// with its own config, key and database (rule D3: nothing crosses workspaces).
public struct NightlySyncRunner: Sendable {
    let root: URL
    let syncer: any NightlyWorkspaceSyncer
    let notifier: any NightlyNotifier
    let ledger: any NightlyLedger
    let now: @Sendable () -> Date

    public init(root: URL, syncer: any NightlyWorkspaceSyncer, notifier: any NightlyNotifier, ledger: any NightlyLedger,
                now: @escaping @Sendable () -> Date) {
        self.root = root; self.syncer = syncer; self.notifier = notifier; self.ledger = ledger; self.now = now
    }

    public func runOnce() async -> [NightlyWorkspaceReport] {
        let registry = WorkspaceRegistry(root: root)
        guard let entries = try? registry.list() else { return [] }
        var reports: [NightlyWorkspaceReport] = []
        for entry in entries {
            reports.append(await run(entry: entry, registry: registry))
        }
        return reports
    }

    func run(entry: WorkspaceEntry, registry: WorkspaceRegistry) async -> NightlyWorkspaceReport {
        var report = NightlyWorkspaceReport(workspaceId: entry.id, name: entry.name, hourUTC: nil, outcome: .notDue, staleNotified: false)
        do {
            let directory = registry.directory(for: entry)
            // In the app, reuse the open session's pool; the login item has nothing registered and opens its own.
            let database = try OpenWorkspaceDatabases.shared.database(for: directory) ?? WorkspaceDatabase.open(at: directory)
            let reader = WorkspaceStateReader(database: database)
            guard let config = try reader.config() else {
                report.outcome = .unreadable("workspace row missing")
                return report
            }
            report.hourUTC = config.nightlySyncHourUTC
            let start = now()
            let due = NightlySchedule.isDue(now: start, hourUTC: config.nightlySyncHourUTC,
                                            lastFinishedSync: try reader.lastFinishedSync(),
                                            lastAttempt: ledger.lastAttempt(workspaceId: entry.id))
            if !due {
                report.outcome = .notDue
            } else if NightlySchedule.applyInProgress(heartbeats: try reader.applyingHeartbeats(), now: start) {
                report.outcome = .skippedApplying
            } else {
                ledger.markAttempt(workspaceId: entry.id, at: start)
                do {
                    let outcome = try await syncer.syncAndCheck(config: config, database: database)
                    report.outcome = .synced(outcome)
                    if outcome.newFindingCount > 0 {
                        await notifier.notifyNewFindings(workspaceName: config.name, count: outcome.newFindingCount)
                    }
                } catch {
                    report.outcome = .failed(String(describing: error))
                }
            }
            let lastComplete = try reader.lastCompleteSync()
            let checkedAt = now()
            if SyncFreshness.shouldNotifyStale(lastCompleteSync: lastComplete, lastNotified: ledger.lastStaleNotice(workspaceId: entry.id),
                                               now: checkedAt) {
                await notifier.notifyStaleSync(workspaceName: config.name, lastCompleteSync: lastComplete)
                ledger.markStaleNotice(workspaceId: entry.id, at: checkedAt)
                report.staleNotified = true
            }
        } catch {
            report.outcome = .unreadable(String(describing: error))
        }
        return report
    }
}
