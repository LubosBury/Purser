import Foundation
import MCPBridge

// purser-mcp: the MCP server an MCP client (Claude Desktop) starts over stdio. It lives in
// "Purser Pricing.app/Contents/MacOS", answers the handshake and the tool list itself and sends every tool call to
// the running app over the socket in the App Group container. It holds no key and never talks to App Store Connect.

/// The helper sits in the app bundle, so `Bundle.main` is the app and its Info.plist names the App Group.
/// PURSER_MCP_SOCKET overrides the path (development builds run from the build folder).
func socketPath() -> String? {
    if let override = ProcessInfo.processInfo.environment["PURSER_MCP_SOCKET"], !override.isEmpty { return override }
    guard let group = (Bundle.main.object(forInfoDictionaryKey: BridgeSocket.appGroupInfoKey) as? String)?.trimmingCharacters(in: .whitespaces),
          !group.isEmpty, !group.hasPrefix("com."), !group.contains("$("),
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
    return BridgeSocket.path(inGroupContainer: container)
}

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let path = socketPath()

let server = MCPStdioServer(serverVersion: version) { name, arguments in
    guard let path else {
        return .failure("purser-mcp must run from inside a signed Purser Pricing app (Contents/MacOS/purser-mcp).")
    }
    do {
        var request = BridgeRequest(tool: name, arguments: arguments)
        if name == MCPToolName.createImportPlan.rawValue { request = try request.inliningCSV(pathKey: "csv_path", textKey: "csv_text") }
        return try BridgeClient.call(request, socketPath: path)
    } catch let error as BridgeFileError {
        return .failure(error.description)
    } catch BridgeError.notListening {
        return .failure("Purser Pricing is not running, or “Let Claude control Purser” is off in its Settings. Open the app, unlock it and open a workspace.")
    } catch {
        return .failure("Purser Pricing could not be reached: \(error)")
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let reply = await server.handle(line: line) {
        print(reply)
        fflush(stdout)
    }
}
