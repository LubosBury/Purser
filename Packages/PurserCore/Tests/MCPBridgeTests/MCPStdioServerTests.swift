import Foundation
import Testing
@testable import MCPBridge

private actor Calls {
    private(set) var seen: [(name: String, arguments: JSONValue)] = []
    func record(_ name: String, _ arguments: JSONValue) { seen.append((name, arguments)) }
}

@Suite struct MCPStdioServerTests {
    private func server(_ calls: Calls = Calls(), result: ToolResult = ToolResult(text: "ok")) -> MCPStdioServer {
        MCPStdioServer(serverVersion: "1.2.3") { name, arguments in
            await calls.record(name, arguments)
            return result
        }
    }

    private func reply(_ server: MCPStdioServer, _ line: String) async throws -> JSONValue {
        let text = try #require(await server.handle(line: line))
        #expect(!text.contains("\n"))
        return try #require(JSONValue.parse(text))
    }

    @Test func initializeEchoesASupportedVersionAndAnnouncesTools() async throws {
        let answer = try await reply(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#)
        #expect(answer["id"] == 1)
        #expect(answer["result"]?["protocolVersion"] == "2024-11-05")
        #expect(answer["result"]?["serverInfo"]?["name"] == "purser")
        #expect(answer["result"]?["serverInfo"]?["version"] == "1.2.3")
        #expect(answer["result"]?["capabilities"]?["tools"] != nil)
    }

    @Test func initializeFallsBackToItsOwnVersionForAnUnknownOne() async throws {
        let answer = try await reply(server(), #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect(answer["id"] == "a")
        #expect(answer["result"]?["protocolVersion"] == .string(MCPStdioServer.protocolVersion))
    }

    @Test func notificationsGetNoReply() async {
        #expect(await server().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func toolsListCarriesEveryToolWithASchema() async throws {
        let answer = try await reply(server(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require(answer["result"]?["tools"]?.arrayValue)
        #expect(tools.count == MCPToolName.allCases.count)
        for tool in tools {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
        let apply = try #require(tools.first { $0["name"] == "apply_plan" })
        #expect(apply["annotations"]?["destructiveHint"] == true)
        #expect(apply["annotations"]?["readOnlyHint"] == false)
        let status = try #require(tools.first { $0["name"] == "purser_status" })
        #expect(status["annotations"]?["readOnlyHint"] == true)
    }

    @Test func toolsCallForwardsNameAndArguments() async throws {
        let calls = Calls()
        let answer = try await reply(server(calls, result: ToolResult(text: "line one\nline two")),
                                     #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_plan","arguments":{"plan_id":"p1","max_rows":5}}}"#)
        #expect(answer["result"]?["isError"] == false)
        #expect(answer["result"]?["content"]?.arrayValue?.first?["text"] == "line one\nline two")
        let seen = await calls.seen
        #expect(seen.count == 1)
        #expect(seen.first?.name == "get_plan")
        #expect(seen.first?.arguments == ["plan_id": "p1", "max_rows": 5])
    }

    @Test func aFailedToolIsAResultWithIsErrorNotAProtocolError() async throws {
        let answer = try await reply(server(result: .failure("Purser is locked.")),
                                     #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"purser_status"}}"#)
        #expect(answer["error"] == nil)
        #expect(answer["result"]?["isError"] == true)
    }

    @Test func unknownToolAndUnknownMethodAreProtocolErrors() async throws {
        let calls = Calls()
        let tool = try await reply(server(calls), #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"drop_everything"}}"#)
        #expect(tool["error"]?["code"] == -32602)
        #expect(await calls.seen.isEmpty)
        let method = try await reply(server(), #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#)
        #expect(method["error"]?["code"] == -32601)
        let garbage = try await reply(server(), "not json")
        #expect(garbage["error"]?["code"] == -32700)
    }

    @Test func everyToolNameHasADefinitionAndWritesAreMarked() {
        #expect(Set(ToolCatalog.all.map(\.name)).count == MCPToolName.allCases.count)
        let writes = Set(ToolCatalog.all.filter { $0.access == .ascWrite }.map(\.name))
        #expect(writes == ["apply_plan", "resume_plan", "create_products"])
        #expect(ToolCatalog.definition(named: "nope") == nil)
    }

    @Test func wholeNumbersEncodeWithoutAFraction() {
        #expect(JSONValue.object(["id": 7, "price": .number(9.99)]).line() == #"{"id":7,"price":9.99}"#)
    }
}
