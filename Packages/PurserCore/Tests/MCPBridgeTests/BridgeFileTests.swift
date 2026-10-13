import Foundation
import Testing
@testable import MCPBridge

@Suite struct BridgeFileTests {
    private func file(_ name: String, _ data: Data) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("purser-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    @Test func aCSVPathIsReplacedByTheFileText() throws {
        let path = try file("prices.CSV", Data("Country,Currency\r\nGermany,EUR\r\n".utf8))
        let request = try BridgeRequest(tool: "create_import_plan", arguments: ["csv_path": .string(path), "canary": true])
            .inliningCSV(pathKey: "csv_path", textKey: "csv_text")
        #expect(request.arguments["csv_text"] == "Country,Currency\r\nGermany,EUR\r\n")
        #expect(request.arguments["csv_path"] == nil)
        #expect(request.arguments["canary"] == true)
        #expect(request.arguments["csv_source"]?.stringValue?.hasSuffix("/prices.CSV") == true)
    }

    @Test func withoutAPathTheRequestIsUnchanged() throws {
        let request = BridgeRequest(tool: "create_import_plan", arguments: ["csv_text": "a,b"])
        #expect(try request.inliningCSV(pathKey: "csv_path", textKey: "csv_text") == request)
    }

    @Test func onlyReadableUTF8CSVFilesWithinTheLimitAreSent() throws {
        func inline(_ arguments: JSONValue, max: Int = 1024) throws -> BridgeRequest {
            try BridgeRequest(tool: "create_import_plan", arguments: arguments).inliningCSV(pathKey: "csv_path", textKey: "csv_text", maxBytes: max)
        }
        let key = try file("id_rsa", Data("secret".utf8))
        #expect(throws: BridgeFileError.wrongExtension(key)) { try inline(["csv_path": .string(key)]) }
        #expect(throws: BridgeFileError.unreadable("/nonexistent/prices.csv")) { try inline(["csv_path": "/nonexistent/prices.csv"]) }
        let big = try file("big.csv", Data(repeating: 0x41, count: 2000))
        #expect(throws: BridgeFileError.tooLarge(big, limit: 1024)) { try inline(["csv_path": .string(big)]) }
        let binary = try file("binary.csv", Data([0xFF, 0xFE, 0x00]))
        #expect(throws: BridgeFileError.notText(binary)) { try inline(["csv_path": .string(binary)]) }
        let ok = try file("ok.csv", Data("a".utf8))
        #expect(throws: BridgeFileError.both("csv_path", "csv_text")) { try inline(["csv_path": .string(ok), "csv_text": "b"]) }
    }
}
