import Foundation
import Observation
import Background
import MCPBridge
import PurserSecurity

/// Stands in for Touch ID on a write that came over the MCP bridge. MCPToolRouter hands it out only while the
/// owner's setting allows writes without Touch ID, and only after the call is in the audit.
struct MCPWriteGate: BiometricGate {
    func authenticate(reason: String) async throws {}
}

/// The app's end of the MCP bridge: the two settings and the socket the `purser-mcp` helper connects to.
/// The bridge is off until the owner turns it on; writes to App Store Connect need the second switch.
@MainActor @Observable
final class MCPBridgeHost {
    private enum Keys {
        static let enabled = "PurserMCPBridgeEnabled"
        static let writesWithoutTouchID = "PurserMCPWritesWithoutTouchID"
    }

    private(set) var isEnabled: Bool
    /// Applies, resumes, product creations and clones asked for over MCP run without Touch ID.
    private(set) var writesWithoutTouchID: Bool
    private(set) var isListening = false
    private(set) var lastError: String?

    private let model: AppModel
    private let defaults: UserDefaults
    @ObservationIgnored private var server: BridgeServer?
    @ObservationIgnored private var router: MCPToolRouter?

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        writesWithoutTouchID = defaults.bool(forKey: Keys.writesWithoutTouchID)
    }

    /// `<app>/Contents/MacOS/purser-mcp`, the command an MCP client runs.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/purser-mcp", isDirectory: false).path
    }

    /// The entry for `claude_desktop_config.json`.
    static var clientConfiguration: String {
        JSONValue.object(["mcpServers": ["purser": ["command": .string(helperPath)]]]).line()
    }

    /// nil in an unsigned build: without the App Group there is no place both sides can reach.
    static func socketPath() -> String? {
        guard let group = GroupPaths.appGroupIdentifier(),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return BridgeSocket.path(inGroupContainer: container)
    }

    var statusText: String {
        if let lastError { return lastError }
        if !isEnabled { return "off" }
        return isListening ? "listening" : "not listening"
    }

    /// Starts or stops the socket to match `isEnabled`; called at launch and after the switch changes.
    func refresh() {
        lastError = nil
        guard isEnabled else {
            server?.stop()
            server = nil
            isListening = false
            return
        }
        guard server == nil else { return }
        guard let path = Self.socketPath() else {
            lastError = "needs a signed build (no App Group)"
            return
        }
        let router = self.router ?? MCPToolRouter(model: model, host: self)
        self.router = router
        let server = BridgeServer(socketPath: path) { request in await router.call(request) }
        do {
            try server.start()
            self.server = server
            isListening = true
        } catch {
            lastError = "the socket could not be opened: \(error)"
            isListening = false
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Keys.enabled)
        logSetting("mcpBridge", enabled)
        refresh()
    }

    /// Turning it on asks for Touch ID once; turning it off never does. Returns the message to show, nil when saved.
    func setWritesWithoutTouchID(_ allowed: Bool) async -> String? {
        guard allowed != writesWithoutTouchID else { return nil }
        if allowed {
            do {
                try await model.environment.gate.authenticate(reason: "let Claude write to App Store Connect without Touch ID")
            } catch {
                return "Allowing writes without Touch ID requires Touch ID."
            }
        }
        writesWithoutTouchID = allowed
        defaults.set(allowed, forKey: Keys.writesWithoutTouchID)
        logSetting("mcpWritesWithoutTouchID", allowed)
        return nil
    }

    /// The settings are per Mac, the audit is per workspace: the open workspace's log gets the change.
    private func logSetting(_ name: String, _ on: Bool) {
        guard case let .open(session) = model.phase else { return }
        try? session.audit.append(.configChanged, refs: ["workspace": session.entry.id.uuidString], payload: [name: on ? "on" : "off"])
    }
}
