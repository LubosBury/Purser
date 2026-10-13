import CryptoKit
import Foundation
import Testing
import Domain
import PurserSecurity
import PurserTestSupport

@Suite struct JWTSignerTests {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    private func parts(_ token: String) throws -> (header: [String: Any], claims: [String: Any], signingInput: String, signature: Data) {
        let segments = token.split(separator: ".")
        try #require(segments.count == 3)
        let headerData = try #require(TestKeys.decodeSegment(segments[0]))
        let header = try #require(try JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        let claims = try #require(TestKeys.claims(of: token))
        let signature = try #require(TestKeys.decodeSegment(segments[2]))
        return (header, claims, "\(segments[0]).\(segments[1])", signature)
    }

    @Test func teamTokenHasIssuerAndVerifies() throws {
        let key = TestKeys.makeKey()
        let signer = try JWTSigner(keyId: "ABCDEF1234", identity: .team(issuerId: "69a6de70-0000-47e3-e053-5b8c7c11a4d1"), privateKeyPEM: key.pem)
        let token = try signer.token(scope: nil, now: now)
        let (header, claims, signingInput, signature) = try parts(token)

        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABCDEF1234")
        #expect(header["typ"] as? String == "JWT")
        #expect(claims["iss"] as? String == "69a6de70-0000-47e3-e053-5b8c7c11a4d1")
        #expect(claims["sub"] == nil)
        #expect(claims["aud"] as? String == "appstoreconnect-v1")
        #expect(claims["scope"] == nil)
        #expect(!token.contains("="))

        #expect(signature.count == 64)
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        #expect(key.publicKey.isValidSignature(ecdsa, for: Data(signingInput.utf8)))
    }

    @Test func individualTokenHasSubjectUser() throws {
        let key = TestKeys.makeKey()
        let signer = try JWTSigner(keyId: "ZYXWVU9876", identity: .individual, privateKeyPEM: key.pem)
        let claims = try parts(try signer.token(scope: nil, now: now)).claims
        #expect(claims["sub"] as? String == "user")
        #expect(claims["iss"] == nil)
        #expect(claims["aud"] as? String == "appstoreconnect-v1")
    }

    @Test func lifetimeIsBelowTwentyMinutes() throws {
        let signer = try JWTSigner(keyId: "ABCDEF1234", identity: .team(issuerId: "issuer"), privateKeyPEM: TestKeys.makeKey().pem)
        let claims = try parts(try signer.token(scope: nil, now: now)).claims
        let iat = try #require(claims["iat"] as? Int)
        let exp = try #require(claims["exp"] as? Int)
        #expect(iat == 1_791_547_200)
        #expect(exp - iat <= 20 * 60)
        #expect(exp - iat == Int(AppleConstants.tokenLifetimeSeconds))
    }

    @Test func scopeIsCopiedVerbatimWithoutEscapedSlashes() throws {
        let signer = try JWTSigner(keyId: "ABCDEF1234", identity: .team(issuerId: "issuer"), privateKeyPEM: TestKeys.makeKey().pem)
        let token = try signer.token(scope: ["GET /v1/subscriptions/6500000001/prices?include=subscriptionPricePoint,territory"], now: now)
        let claims = try parts(token).claims
        #expect(claims["scope"] as? [String] == ["GET /v1/subscriptions/6500000001/prices?include=subscriptionPricePoint,territory"])
        let payloadSegment = token.split(separator: ".")[1]
        let payloadText = String(decoding: try #require(TestKeys.decodeSegment(payloadSegment)), as: UTF8.self)
        #expect(!payloadText.contains("\\/"))
    }

    @Test func rejectsAnInvalidKey() {
        #expect(throws: JWTError.invalidPrivateKey) {
            try JWTSigner(keyId: "ABCDEF1234", identity: .individual, privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----")
        }
    }
}
