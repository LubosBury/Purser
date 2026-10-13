import CryptoKit
import Foundation
import Domain

public enum JWTIdentity: Hashable, Sendable { case team(issuerId: String), individual }

public enum JWTError: Error, Equatable { case invalidPrivateKey }

/// ES256 tokens for the ASC API. Team keys carry "iss"; individual keys carry "sub": "user" (T3-33).
public struct JWTSigner: Sendable {
    private let keyId: String
    private let identity: JWTIdentity
    private let rawKey: Data

    public init(keyId: String, identity: JWTIdentity, privateKeyPEM: String) throws {
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM) else {
            throw JWTError.invalidPrivateKey
        }
        self.keyId = keyId
        self.identity = identity
        self.rawKey = key.rawRepresentation
    }

    /// `scope` = nil for an unscoped (write-capable) token; otherwise e.g. ["GET /v1/apps/123"]. Carries a random `jti`.
    public func token(scope: [String]?, now: Date) throws -> String {
        try token(scope: scope, now: now, jti: UUID().uuidString)
    }

    /// Same as `token(scope:now:)` with a caller-chosen `jti` (spec §5: the audit keeps keyId and jti, never the token).
    package func token(scope: [String]?, now: Date, jti: String) throws -> String {
        let key = try P256.Signing.PrivateKey(rawRepresentation: rawKey)
        let issuedAt = Int(now.timeIntervalSince1970)
        let expiresAt = issuedAt + Int(AppleConstants.tokenLifetimeSeconds)
        let claims: Claims
        switch identity {
        case let .team(issuerId):
            claims = Claims(iss: issuerId, sub: nil, iat: issuedAt, exp: expiresAt, aud: "appstoreconnect-v1", scope: scope, jti: jti)
        case .individual:
            claims = Claims(iss: nil, sub: "user", iat: issuedAt, exp: expiresAt, aud: "appstoreconnect-v1", scope: scope, jti: jti)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signingInput = Self.base64URL(try encoder.encode(Header(alg: "ES256", kid: keyId, typ: "JWT")))
            + "." + Self.base64URL(try encoder.encode(claims))
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct Header: Encodable {
        let alg: String
        let kid: String
        let typ: String
    }

    private struct Claims: Encodable {
        let iss: String?
        let sub: String?
        let iat: Int
        let exp: Int
        let aud: String
        let scope: [String]?
        let jti: String
    }
}
