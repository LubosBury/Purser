import Foundation
import Observation
import ASCClient
import Importer

/// The Google account of one workspace: sign-in state and access tokens for the Sheets import.
/// Token storage is injected as closures over the workspace's Keychain item SecretAccount.googleToken(workspace).
@MainActor
@Observable
final class GoogleAccount {
    @ObservationIgnored let transport: any HTTPTransport
    @ObservationIgnored private let loadToken: @Sendable () throws -> Data?
    @ObservationIgnored private let saveToken: @Sendable (Data) throws -> Void

    private(set) var isSignedIn: Bool
    var lastError: String?

    init(transport: any HTTPTransport, loadToken: @escaping @Sendable () throws -> Data?, saveToken: @escaping @Sendable (Data) throws -> Void) {
        self.transport = transport
        self.loadToken = loadToken
        self.saveToken = saveToken
        isSignedIn = ((try? loadToken()) ?? nil) != nil
    }

    func signIn(clientId: String) async {
        let session = GoogleAuthSession(clientId: clientId, transport: transport, saveToken: saveToken)
        do {
            try await session.signIn()
            isSignedIn = true
            lastError = nil
        } catch {
            lastError = "Google sign-in failed: \(error)"
        }
    }

    /// Access tokens for GoogleSheetsTableSource; refreshes through the token endpoint when needed.
    func tokenProvider(clientId: String) -> GoogleAccessTokenProvider {
        GoogleAccessTokenProvider(clientId: clientId, transport: transport, load: loadToken, save: saveToken, now: { Date() })
    }
}
