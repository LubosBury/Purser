import Foundation
import Testing
@testable import MCPBridge

@Suite struct BridgeSocketTests {
    /// Short on purpose: a Unix socket path holds about 100 bytes and the test temporary directory is already long.
    private func socketPath() -> String {
        "/tmp/purser-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func aCallReachesTheHandlerAndItsResultComesBack() async throws {
        let path = socketPath()
        let server = BridgeServer(socketPath: path) { request in
            ToolResult(text: "\(request.tool):\(request.arguments["plan_id"]?.stringValue ?? "-")\nsecond line", isError: request.tool == "fail")
        }
        try server.start()
        defer { server.stop() }
        let ok = try await Task.detached { try BridgeClient.call(BridgeRequest(tool: "get_plan", arguments: ["plan_id": "p1"]), socketPath: path, timeout: 5) }.value
        #expect(ok == ToolResult(text: "get_plan:p1\nsecond line"))
        let failed = try await Task.detached { try BridgeClient.call(BridgeRequest(tool: "fail", arguments: [:]), socketPath: path, timeout: 5) }.value
        #expect(failed.isError)
    }

    @Test func theSocketIsPrivateToTheUserAndGoneAfterStop() throws {
        let path = socketPath()
        let server = BridgeServer(socketPath: path) { _ in ToolResult(text: "") }
        try server.start()
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(server.isRunning)
        server.stop()
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func withoutAListenerTheClientReportsNotListening() {
        #expect(throws: BridgeError.notListening) {
            try BridgeClient.call(BridgeRequest(tool: "purser_status", arguments: [:]), socketPath: socketPath(), timeout: 1)
        }
    }

    @Test func aStaleSocketFileDoesNotBlockTheNextStart() async throws {
        let path = socketPath()
        let first = BridgeServer(socketPath: path) { _ in ToolResult(text: "first") }
        try first.start()
        // A crashed run leaves the file behind: the second server must take the path over.
        let second = BridgeServer(socketPath: path) { _ in ToolResult(text: "second") }
        try second.start()
        defer { second.stop() }
        let result = try await Task.detached { try BridgeClient.call(BridgeRequest(tool: "x", arguments: [:]), socketPath: path, timeout: 5) }.value
        #expect(result.text == "second")
    }

    @Test func anOverlongPathIsRefused() {
        let path = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        #expect(throws: BridgeError.pathTooLong(path)) {
            try BridgeServer(socketPath: path) { _ in ToolResult(text: "") }.start()
        }
    }
}
