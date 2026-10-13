import Foundation
import Testing
import PurserSecurity
import PurserTestSupport

@Suite("JWT token id")
struct JWTSignerTokenIdTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    @Test func everyTokenCarriesAFreshUUIDJti() throws {
        let signer = try JWTSigner(keyId: "ABCDEF1234", identity: .individual, privateKeyPEM: TestKeys.makeKey().pem)
        let first = try #require(TestKeys.claims(of: try signer.token(scope: nil, now: now))?["jti"] as? String)
        let second = try #require(TestKeys.claims(of: try signer.token(scope: nil, now: now))?["jti"] as? String)
        #expect(first.count == 36)
        #expect(UUID(uuidString: first) != nil)
        #expect(first != second)
    }

    @Test func explicitJtiIsUsedVerbatimForBothIdentities() throws {
        let team = try JWTSigner(keyId: "ABCDEF1234", identity: .team(issuerId: "issuer"), privateKeyPEM: TestKeys.makeKey().pem)
        let individual = try JWTSigner(keyId: "ZYXWVU9876", identity: .individual, privateKeyPEM: TestKeys.makeKey().pem)
        let teamClaims = try #require(TestKeys.claims(of: try team.token(scope: nil, now: now, jti: "6F1C0F55-0000-4000-8000-0000000000AA")))
        let individualClaims = try #require(TestKeys.claims(of: try individual.token(scope: ["GET /v1/apps/1"], now: now, jti: "6F1C0F55-0000-4000-8000-0000000000BB")))
        #expect(teamClaims["jti"] as? String == "6F1C0F55-0000-4000-8000-0000000000AA")
        #expect(teamClaims["iss"] as? String == "issuer")
        #expect(individualClaims["jti"] as? String == "6F1C0F55-0000-4000-8000-0000000000BB")
        #expect(individualClaims["sub"] as? String == "user")
        #expect(individualClaims["scope"] as? [String] == ["GET /v1/apps/1"])
    }
}
