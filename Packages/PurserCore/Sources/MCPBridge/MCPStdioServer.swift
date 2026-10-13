import Foundation

/// What a tool call returns to the model: text, and whether it reports a failure.
public struct ToolResult: Hashable, Sendable, Codable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text; self.isError = isError
    }

    public static func failure(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }
}

/// MCP over newline-delimited JSON-RPC 2.0 (the stdio transport). Answers `initialize`, `ping` and `tools/list`
/// itself and hands `tools/call` to `callTool`, so the helper works while the app is closed.
public struct MCPStdioServer: Sendable {
    public static let protocolVersion = "2025-06-18"
    private static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let serverVersion: String
    private let tools: [ToolDefinition]
    private let callTool: @Sendable (String, JSONValue) async -> ToolResult

    public init(serverVersion: String, tools: [ToolDefinition] = ToolCatalog.all,
                callTool: @escaping @Sendable (String, JSONValue) async -> ToolResult) {
        self.serverVersion = serverVersion; self.tools = tools; self.callTool = callTool
    }

    /// The reply to one incoming line; nil for notifications and for lines that need no answer.
    public func handle(line: String) async -> String? {
        guard let message = JSONValue.parse(line), case .object = message else {
            return Self.error(id: .null, code: -32700, message: "Parse error")
        }
        guard let method = message["method"]?.stringValue else {
            // A response to a request of ours (we send none) or garbage with an id.
            return nil
        }
        guard let id = message["id"], !id.isNull else { return nil }   // notification
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.protocolVersion
            let version = Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "purser", "title": "Purser Pricing", "version": .string(serverVersion)],
                "instructions": "Purser reviews and applies App Store Connect prices for one app. Call purser_status first: the app must be running, unlocked and have a workspace open. Plans are built as Drafts and reviewed with get_plan before apply_plan; App Store Connect has no sandbox.",
            ])
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, ["tools": .array(tools.map(Self.describe))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "tools/call needs a tool name")
            }
            guard tools.contains(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let result = await callTool(name, params["arguments"] ?? .object([:]))
            return Self.result(id: id, ["content": [["type": "text", "text": .string(result.text)]], "isError": .bool(result.isError)])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func describe(_ tool: ToolDefinition) -> JSONValue {
        ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema,
         "annotations": ["readOnlyHint": .bool(tool.access == .read), "destructiveHint": .bool(tool.access == .ascWrite),
                         "openWorldHint": .bool(tool.access != .read)]]
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).line()
    }

    private static func error(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]).line()
    }
}
