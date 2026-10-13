import Foundation
import ASCClient

/// Hands out a valid access token, refreshing it through the token endpoint when it is about to expire.
/// Storage is injected (the app passes Keychain closures for SecretAccount.googleToken).
public actor GoogleAccessTokenProvider {
    private let clientId: String
    private let transport: any HTTPTransport
    private let load: @Sendable () throws -> Data?
    private let save: @Sendable (Data) throws -> Void
    private let now: @Sendable () -> Date

    public init(clientId: String, transport: any HTTPTransport,
                load: @escaping @Sendable () throws -> Data?, save: @escaping @Sendable (Data) throws -> Void,
                now: @escaping @Sendable () -> Date) {
        self.clientId = clientId; self.transport = transport; self.load = load; self.save = save; self.now = now
    }

    public func store(_ token: GoogleToken) throws {
        try save(try JSONEncoder().encode(token))
    }

    public func currentToken() throws -> GoogleToken? {
        guard let data = try load() else { return nil }
        return try JSONDecoder().decode(GoogleToken.self, from: data)
    }

    public func accessToken() async throws -> String {
        guard let token = try currentToken() else { throw GoogleOAuthError.notSignedIn }
        if token.isFresh(at: now()) { return token.accessToken }
        guard let refresh = token.refreshToken else { throw GoogleOAuthError.notSignedIn }
        let (data, response) = try await transport.send(GoogleOAuth.refreshRequest(clientId: clientId, refreshToken: refresh))
        let renewed = try GoogleOAuth.parseTokenResponse(data: data, status: response.statusCode, now: now(), previousRefreshToken: refresh)
        try store(renewed)
        return renewed.accessToken
    }
}
