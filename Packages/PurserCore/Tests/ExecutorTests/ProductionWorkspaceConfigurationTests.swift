import CryptoKit
import Foundation
import Testing
import Domain
import Store
import PurserSecurity
import ASCClient
import Policy

/// M5: a production workspace (individual key, isProduction = true) must work with the existing code.
/// These tests characterise behaviour delivered in M0-M2; they must pass without production code changes.
@Suite("Production workspace configuration")
struct ProductionWorkspaceConfigurationTests {
    static let productionConfig = WorkspaceConfig(
        id: UUID(uuidString: "5A1E0000-0000-4000-8000-000000000002")!,
        name: "Produkce Example",
        colorHex: "#C62828",
        isProduction: true,
        appId: "6400000002",
        bundleId: "com.example.produkce",
        keyKind: .individual,
        keyId: "INDKEY0002",
        issuerId: nil,
        importMapping: nil,
        googleClientId: nil,
        slackWebhookEnabled: false,
        nightlySyncHourUTC: 4)

    static let developmentConfig = WorkspaceConfig(
        id: UUID(uuidString: "5A1E0000-0000-4000-8000-000000000001")!,
        name: "Dev Example",
        colorHex: "#2E7D32",
        isProduction: false,
        appId: "6400000001",
        bundleId: "com.example.dev",
        keyKind: .team,
        keyId: "TEAMKEY001",
        issuerId: "00000000-0000-4000-8000-0000000000aa",
        importMapping: nil,
        googleClientId: nil,
        slackWebhookEnabled: false,
        nightlySyncHourUTC: 3)

    static let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func productionWorkspaceRequiresC1WithoutAnyVerdict() {
        #expect(PolicyEngine.confirmationLevel(for: [], config: Self.productionConfig) == .c1)
        #expect(PolicyEngine.confirmationLevel(for: [], config: Self.developmentConfig) == .c0)
    }

    @Test func c2VerdictStillWinsOnProductionWorkspace() {
        let verdict = Verdict(rule: "R7", severity: .confirm(.c2), cell: nil,
                              message: "regular price decrease", riskClass: "R7 regular price decrease")
        #expect(PolicyEngine.confirmationLevel(for: [verdict], config: Self.productionConfig) == .c2)
    }

    @Test func planBindingOfIndividualKeyCarriesNoIssuer() {
        let binding = PlanBinding(config: Self.productionConfig)
        #expect(binding.keyKind == .individual)
        #expect(binding.issuerId == nil)
        #expect(binding.keyId == "INDKEY0002")
        #expect(binding.appId == "6400000002")
        #expect(binding.bundleId == "com.example.produkce")
        #expect(binding != PlanBinding(config: Self.developmentConfig))
    }

    @Test func rotatedKeyChangesPlanBinding() {
        var rotated = Self.productionConfig
        rotated.keyId = "INDKEY0003"
        #expect(PlanBinding(config: rotated) != PlanBinding(config: Self.productionConfig))
    }

    @Test func productionConfigRoundTripsThroughJSONCoding() throws {
        let json = try JSONCoding.string(Self.productionConfig)
        let decoded = try JSONCoding.decode(WorkspaceConfig.self, from: json)
        #expect(decoded == Self.productionConfig)
        #expect(decoded.isProduction)
        #expect(decoded.keyKind == .individual)
    }

    @Test func individualKeyTokenUsesSubUserAndNoIssuer() throws {
        let key = P256.Signing.PrivateKey()
        let signer = try JWTSigner(keyId: "INDKEY0002", identity: .individual, privateKeyPEM: key.pemRepresentation)
        let token = try signer.token(scope: nil, now: Self.fixedNow)
        let parts = token.split(separator: ".").map(String.init)
        try #require(parts.count == 3)

        let header = try Self.jsonObject(parts[0])
        let payload = try Self.jsonObject(parts[1])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "INDKEY0002")
        #expect(payload["sub"] as? String == "user")
        #expect(!payload.keys.contains("iss"))
        #expect(!payload.keys.contains("scope"))
        #expect(payload["aud"] as? String == "appstoreconnect-v1")
        let issuedAt = try #require(payload["iat"] as? Double)
        let expiresAt = try #require(payload["exp"] as? Double)
        #expect(expiresAt > Self.fixedNow.timeIntervalSince1970)
        #expect(expiresAt - issuedAt <= 20 * 60)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try Self.base64URLDecode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func individualKeyScopedTokenListsOnlyRequestedPaths() throws {
        let key = P256.Signing.PrivateKey()
        let signer = try JWTSigner(keyId: "INDKEY0002", identity: .individual, privateKeyPEM: key.pemRepresentation)
        let token = try signer.token(scope: ["GET /v1/apps/6400000002"], now: Self.fixedNow)
        let parts = token.split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        let payload = try Self.jsonObject(parts[1])
        #expect(payload["scope"] as? [String] == ["GET /v1/apps/6400000002"])
        #expect(payload["sub"] as? String == "user")
        #expect(!payload.keys.contains("iss"))
    }

    @Test func appGuardOfProductionWorkspaceRefusesAnotherApp() async throws {
        let appGuard = AppGuard(appId: "6400000002")
        try await appGuard.check(method: "GET", path: "/v1/apps/6400000002", body: nil)
        do {
            try await appGuard.check(method: "GET", path: "/v1/apps/6400000003", body: nil)
            Issue.record("AppGuard allowed a request for another app")
        } catch let error as ASCError {
            guard case .foreignResource = error else {
                Issue.record("Expected ASCError.foreignResource, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    static func base64URLDecode(_ segment: String) throws -> Data {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return try #require(Data(base64Encoded: base64))
    }

    static func jsonObject(_ segment: String) throws -> [String: Any] {
        let data = try base64URLDecode(segment)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
