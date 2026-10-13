import Foundation
import Testing
import Domain
import PurserSecurity
@testable import ASCClient
import PurserTestSupport

private actor HeaderTransport: HTTPTransport {
    private var headers: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func recorded() -> [String] { headers }
}

private func jti(_ authorization: String) -> String? {
    TestKeys.claims(of: String(authorization.dropFirst("Bearer ".count)))?["jti"] as? String
}

@Suite("Token id propagation")
struct TokenIdPropagationTests {
    @Test func theTaskLocalTokenIdBecomesTheJtiOfThatRequestOnly() async throws {
        let transport = HeaderTransport()
        let guardian = AppGuard(appId: "1000000001")
        await guardian.allowChildren(["price-1", "price-2"])
        let signer = try JWTSigner(keyId: "TESTKEY001", identity: .team(issuerId: "11111111-2222-3333-4444-555555555555"),
                                   privateKeyPEM: TestKeys.makeKey().pem)
        let client = ASCHTTPClient(transport: transport, signer: signer, budget: RateBudget(now: { Date() }, sleep: { _ in }),
                                   appGuard: guardian, readOnly: false, now: { Date() })
        try await ASCRequestContext.$tokenId.withValue("6F1C0F55-0000-4000-8000-0000000000CC") {
            try await client.delete(path: "/v1/subscriptionPrices/price-1")
        }
        try await client.delete(path: "/v1/subscriptionPrices/price-2")
        let headers = await transport.recorded()
        #expect(headers.count == 2)
        #expect(jti(headers[0]) == "6F1C0F55-0000-4000-8000-0000000000CC")
        let other = try #require(jti(headers[1]))
        #expect(other.count == 36)
        #expect(other != "6F1C0F55-0000-4000-8000-0000000000CC")
    }
}
