import Foundation
import Observation
import Domain
import Store
import PurserSecurity

/// Owner name, lock and the one open workspace (K11).
@Observable @MainActor
final class AppModel {
    enum Phase {
        /// No owner name yet: the first launch asks for it.
        case needsOwner
        case locked
        case picking
        case open(WorkspaceSession)
    }

    private(set) var phase: Phase = .needsOwner
    private(set) var workspaces: [WorkspaceEntry] = []
    var errorMessage: String?

    let environment: AppEnvironment
    /// The audit actor (spec D2). A label for the log; access is Touch ID.
    private(set) var ownerName: String?
    private(set) var auditActor: AuditActor?
    private var signInToLog = false
    private var lastActivity = Date()
    /// Unlock, create and open that follow each other ask for Touch ID once; lock() forgets it.
    private var recentAuthentication = RecentAuthentication()
    private var suspended: WorkspaceSession?
    private var inactivityTask: Task<Void, Never>?
    private var launched = false

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var owners: OwnerRegistry { OwnerRegistry(store: environment.secretStore) }
    var registry: WorkspaceRegistry { WorkspaceRegistry(root: environment.registryRoot) }

    // MARK: - Launch, owner, lock

    func launch() async {
        guard !launched else { return }
        launched = true
        startInactivityTimer()
        do {
            guard let owner = try owners.owner() else {
                phase = .needsOwner
                return
            }
            adopt(owner)
            phase = .locked
            await unlock()
        } catch {
            phase = .needsOwner
            errorMessage = "The Keychain cannot be read: \(error)"
        }
    }

    /// First launch: stores the name and goes on to Touch ID.
    func setOwner(name: String) async {
        do {
            adopt(try owners.setOwner(name: name))
            signInToLog = true
            phase = .locked
            await unlock()
        } catch OwnerError.emptyName {
            errorMessage = "Enter a name."
        } catch {
            errorMessage = "The name could not be saved to the Keychain: \(error)"
        }
    }

    /// Settings: always asks for Touch ID. The open workspace's audit gets configChanged under the old name first;
    /// with no workspace open there is no log to write to and later events simply carry the new name.
    /// Returns the message to show, nil when the name is saved (or unchanged).
    func renameOwner(to name: String) async -> String? {
        guard let auditActor, let previous = ownerName else { return "Unlock Purser first." }
        let session: WorkspaceSession?
        switch phase {
        case .needsOwner, .locked: return "Unlock Purser first."
        case .picking: session = nil
        case let .open(open): session = open
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a name." }
        guard trimmed != previous else { return nil }
        do {
            try await environment.gate.authenticate(reason: "change the name in the audit")
        } catch {
            return "Changing the name requires Touch ID."
        }
        do {
            try session?.audit.append(.configChanged, refs: ["workspace": session?.entry.id.uuidString ?? ""],
                                      payload: ["ownerName": trimmed, "previousOwnerName": previous])
            try owners.setOwner(name: trimmed)
        } catch {
            return "The name could not be changed: \(error)"
        }
        auditActor.name = trimmed
        ownerName = trimmed
        noteActivity()
        return nil
    }

    private func adopt(_ name: String) {
        ownerName = name
        if let auditActor { auditActor.name = name } else { auditActor = AuditActor(name) }
    }

    func unlock() async {
        do {
            try await environment.gate.authenticate(reason: "unlock Purser")
        } catch {
            errorMessage = "Unlocking failed."
            return
        }
        recentAuthentication.noteSuccess(at: Date())
        noteActivity()
        if let session = suspended {
            suspended = nil
            phase = .open(session)
        } else {
            reloadWorkspaces()
            phase = .picking
        }
    }

    func lock() {
        ApplyController.current?.broker.cancelIfWaiting()
        if case let .open(session) = phase { suspended = session }
        if case .needsOwner = phase { return }
        recentAuthentication.invalidate()
        phase = .locked
    }

    /// Touch ID unless one succeeded within RecentAuthentication.defaultWindow. Not for applies or key changes.
    func authenticateUnlessRecent(reason: String) async throws {
        if recentAuthentication.covers(Date()) { return }
        try await environment.gate.authenticate(reason: reason)
        recentAuthentication.noteSuccess(at: Date())
    }

    func noteActivity() {
        lastActivity = Date()
    }

    /// Locks after AppleConstants.inactivityLockSeconds without input (spec D2).
    func checkInactivity(now: Date) {
        // A confirmation sheet is open: the owner is deciding; never lock under it.
        if ApplyController.current?.broker.pending != nil {
            noteActivity()
            return
        }
        // A sync is running: waiting for it is not inactivity.
        if case let .open(session) = phase, session.isSyncing {
            noteActivity()
            return
        }
        switch phase {
        case .open, .picking:
            if now.timeIntervalSince(lastActivity) >= inactivityLimit { lock() }
        case .needsOwner, .locked:
            break
        }
    }

    /// Debug builds accept `-PurserInactivitySeconds <n>` as a launch argument for manual verification.
    private var inactivityLimit: TimeInterval {
        #if DEBUG
        let override = UserDefaults.standard.double(forKey: "PurserInactivitySeconds")
        if override > 0 { return override }
        #endif
        return AppleConstants.inactivityLockSeconds
    }

    private func startInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.checkInactivity(now: Date())
            }
        }
    }

    // MARK: - Workspaces

    func reloadWorkspaces() {
        do {
            workspaces = try registry.list()
        } catch {
            errorMessage = "The list of workspaces cannot be loaded: \(error)"
        }
    }

    /// Opening (and so switching) always asks for Touch ID and closes the previous session first (spec §4).
    func open(_ entry: WorkspaceEntry) async {
        guard let auditActor else { return }
        do {
            try await authenticateUnlessRecent(reason: "open the workspace \(entry.name)")
        } catch {
            errorMessage = "Opening a workspace requires Touch ID."
            return
        }
        closeSessions()
        do {
            let session = try WorkspaceSession.open(entry: entry, registry: registry, environment: environment,
                                                    owner: auditActor, logSignIn: signInToLog)
            signInToLog = false
            phase = .open(session)
            noteActivity()
        } catch {
            phase = .picking
            errorMessage = "The workspace \(entry.name) cannot be opened: \(error)"
        }
    }

    func leaveWorkspace() {
        closeSessions()
        reloadWorkspaces()
        phase = .picking
    }

    private func closeSessions() {
        if case let .open(session) = phase { session.close() }
        suspended?.close()
        suspended = nil
    }
}
