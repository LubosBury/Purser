import CryptoKit
import Foundation
import ASCClient
import PurserSecurity

/// Write-capable or read-only HTTP clients over any transport, with a throwaway P-256 key.
public enum WriteTestClients {
    public static let appId = "1000000001"
    public static let teamIdentity = JWTIdentity.team(issuerId: "11111111-2222-3333-4444-555555555555")

    public static func signer(identity: JWTIdentity = teamIdentity) throws -> JWTSigner {
        try JWTSigner(keyId: "TESTKEY001", identity: identity, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
    }

    /// Pass the same `appGuard` to a read and a write client so ids registered by reads are writable (as in WorkspaceSession).
    public static func http(transport: any HTTPTransport, readOnly: Bool, products: Set<String>,
                            children: Set<String> = [], budget: RateBudget? = nil, appGuard shared: AppGuard? = nil,
                            identity: JWTIdentity = teamIdentity,
                            now: @escaping @Sendable () -> Date = { Date() }) async throws -> ASCHTTPClient {
        let appGuard = shared ?? AppGuard(appId: appId)
        await appGuard.allowProducts(products)
        await appGuard.allowChildren(children)
        let rateBudget = budget ?? RateBudget(now: now, sleep: { _ in })
        return ASCHTTPClient(transport: transport, signer: try signer(identity: identity), budget: rateBudget, appGuard: appGuard,
                             readOnly: readOnly, now: now)
    }
}
