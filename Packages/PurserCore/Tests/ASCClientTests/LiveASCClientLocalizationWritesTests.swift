import Foundation
import Testing
import Domain
@testable import ASCClient
import PurserTestSupport

private actor ScriptedTransport: HTTPTransport {
    private var queue: [(status: Int, body: String)]
    private var requests: [URLRequest] = []

    init(_ responses: [(status: Int, body: String)]) { queue = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (Data(next.body.utf8), response)
    }

    func recorded() -> [URLRequest] { requests }
}

private func canonical(_ data: Data?) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data ?? Data())
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

@Suite("LiveASCClient localization writes")
struct LiveASCClientLocalizationWritesTests {
    let owner = LocalizationOwner.subscription("sub-1")

    @Test func aPostSendsTheGoldenBodyAndItsReturnedIdBecomesPatchable() async throws {
        let transport = ScriptedTransport([
            (201, #"{"data":{"type":"subscriptionLocalizations","id":"loc-77","attributes":{"name":"Ovoce","locale":"cs","description":"Všechno"},"relationships":{"version":{"data":{"type":"subscriptionVersions","id":"ver-2"}}}}}"#),
            (200, #"{"data":{"type":"subscriptionLocalizations","id":"loc-77","attributes":{"name":"Ovoce 2","locale":"cs","description":"Všechno"}}}"#),
        ])
        let client = LiveASCClient(http: try await WriteTestClients.http(transport: transport, readOnly: false, products: ["sub-1"], children: ["ver-2"]))
        let text = LocalizationText(name: "Ovoce", description: "Všechno")
        let row = try await client.createLocalization(versionId: "ver-2", owner: owner, locale: "cs", text: text)
        #expect(row == LocalizationRow(ascId: "loc-77", owner: owner, versionId: "ver-2", locale: "cs", text: text))
        try await client.updateLocalization(localizationId: "loc-77", owner: owner, text: LocalizationText(name: "Ovoce 2"))
        let sent = await transport.recorded()
        #expect(sent.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
                == ["POST /v2/subscriptionLocalizations", "PATCH /v2/subscriptionLocalizations/loc-77"])
        #expect(try canonical(sent[0].httpBody) == canonical(try WriteBodies.createLocalization(versionId: "ver-2", owner: owner, locale: "cs", text: text).data()))
        #expect(try canonical(sent[1].httpBody)
                == canonical(Data(#"{"data":{"type":"subscriptionLocalizations","id":"loc-77","attributes":{"name":"Ovoce 2"}}}"#.utf8)))
    }

    @Test func aPatchOfAnUnknownIdNeverLeaves() async throws {
        let transport = ScriptedTransport([])
        let client = LiveASCClient(http: try await WriteTestClients.http(transport: transport, readOnly: false, products: ["sub-1"]))
        await #expect(throws: ASCError.foreignResource("/v2/subscriptionLocalizations/loc-9")) {
            try await client.updateLocalization(localizationId: "loc-9", owner: owner, text: LocalizationText(name: "X"))
        }
        #expect(await transport.recorded().isEmpty)
    }
}
