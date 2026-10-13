#if DEBUG
import Foundation
import Domain
import PurserSecurity
import ASCClient
import Executor

extension WorkspaceSession {
    /// DEBUG only (K11): a SpikeProbe with its own write-capable client for one Spike konzole session. The session never
    /// stores it; the key is read from the Keychain now and every write asks for Touch ID inside the probe.
    func makeSpikeProbe() throws -> SpikeProbe {
        guard !config.isProduction else { throw SpikeProbeError.productionWorkspace }
        guard let readClient else { throw WorkspaceSessionError.syncUnavailable }
        guard let pem = try secretStore.get(account: SecretAccount.ascPrivateKey(config.id)) else { throw WorkspaceSessionError.missingKey }
        let identity: JWTIdentity = config.keyKind == .team ? .team(issuerId: config.issuerId ?? "") : .individual
        let signer = try JWTSigner(keyId: config.keyId, identity: identity, privateKeyPEM: String(decoding: pem, as: UTF8.self))
        let http = ASCHTTPClient(transport: URLSessionTransport(), signer: signer, budget: budget, appGuard: appGuard,
                                 readOnly: false, now: { Date() })
        return SpikeProbe(config: config, http: http, reader: readClient, catalog: catalogStore, plans: planStore, audit: audit,
                          budget: budget, gate: biometricGate, now: { Date() })
    }
}
#endif
