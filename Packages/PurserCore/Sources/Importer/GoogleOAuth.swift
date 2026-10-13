import CryptoKit
import Foundation

public enum GoogleOAuthError: Error, Equatable {
    case stateMismatch
    case missingCode
    case authorizationDenied(String)
    case tokenEndpoint(status: Int, message: String)
    case malformedTokenResponse
    case notSignedIn
}

/// Tokens as stored in the Keychain (SecretAccount.googleToken). Never logged.
public struct GoogleToken: Hashable, Sendable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }

    public func isFresh(at now: Date, margin: TimeInterval = 60) -> Bool { expiresAt.timeIntervalSince(now) > margin }
}

/// PKCE helpers and token exchange for the desktop OAuth flow; the browser part lives in App/Google.
public enum GoogleOAuth {
    public static let scope = "https://www.googleapis.com/auth/spreadsheets.readonly"
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// RFC 7636 code verifier: 32 random bytes, base64url without padding (43 characters).
    public static func makeVerifier() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    /// RFC 7636 S256 challenge: base64url(SHA256(ASCII(verifier))).
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// "123-abc.apps.googleusercontent.com" -> "com.googleusercontent.apps.123-abc" (the iOS client callback scheme).
    public static func reversedClientId(_ clientId: String) -> String {
        clientId.split(separator: ".").reversed().joined(separator: ".")
    }

    public static func redirectURI(clientId: String) -> String {
        "\(reversedClientId(clientId)):/oauth2redirect"
    }

    public static func authorizationURL(clientId: String, redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    public static func tokenRequest(clientId: String, redirectURI: String, code: String, verifier: String) -> URLRequest {
        formRequest([
            ("client_id", clientId), ("code", code), ("code_verifier", verifier),
            ("grant_type", "authorization_code"), ("redirect_uri", redirectURI),
        ])
    }

    public static func refreshRequest(clientId: String, refreshToken: String) -> URLRequest {
        formRequest([("client_id", clientId), ("grant_type", "refresh_token"), ("refresh_token", refreshToken)])
    }

    /// Reads `code` from the callback URL after checking `state`.
    public static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw GoogleOAuthError.authorizationDenied(error) }
        guard value("state") == expectedState else { throw GoogleOAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw GoogleOAuthError.missingCode }
        return code
    }

    /// Parses the token endpoint response. A refresh response carries no refresh_token, so the previous one is kept.
    public static func parseTokenResponse(data: Data, status: Int, now: Date, previousRefreshToken: String?) throws -> GoogleToken {
        struct Body: Decodable {
            var access_token: String?
            var expires_in: Double?
            var refresh_token: String?
            var error: String?
            var error_description: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            if !(200..<300).contains(status) { throw GoogleOAuthError.tokenEndpoint(status: status, message: "") }
            throw GoogleOAuthError.malformedTokenResponse
        }
        guard (200..<300).contains(status) else {
            throw GoogleOAuthError.tokenEndpoint(status: status, message: [body.error, body.error_description].compactMap { $0 }.joined(separator: ": "))
        }
        guard let access = body.access_token, let expiresIn = body.expires_in else { throw GoogleOAuthError.malformedTokenResponse }
        return GoogleToken(accessToken: access, refreshToken: body.refresh_token ?? previousRefreshToken,
                           expiresAt: now.addingTimeInterval(expiresIn))
    }

    static func formRequest(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
