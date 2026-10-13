import AppKit
import AuthenticationServices
import Foundation
import ASCClient
import Importer

/// Google sign-in for the import (read-only Sheets scope): ASWebAuthenticationSession with the reversed client id as the
/// callback scheme, PKCE (RFC 7636), token exchange through `transport`. The token JSON goes to `saveToken`
/// (Keychain, SecretAccount.googleToken(workspace)); nothing is logged.
@MainActor
final class GoogleAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let clientId: String
    private let transport: any HTTPTransport
    private let saveToken: @Sendable (Data) throws -> Void
    private var session: ASWebAuthenticationSession?

    init(clientId: String, transport: any HTTPTransport, saveToken: @escaping @Sendable (Data) throws -> Void) {
        self.clientId = clientId
        self.transport = transport
        self.saveToken = saveToken
    }

    func signIn() async throws {
        let verifier = GoogleOAuth.makeVerifier()
        let state = UUID().uuidString
        let redirectURI = GoogleOAuth.redirectURI(clientId: clientId)
        let url = GoogleOAuth.authorizationURL(clientId: clientId, redirectURI: redirectURI,
                                               challenge: GoogleOAuth.challenge(for: verifier), state: state)
        let callback = try await present(url: url, scheme: GoogleOAuth.reversedClientId(clientId))
        let code = try GoogleOAuth.authorizationCode(from: callback, expectedState: state)
        let (data, response) = try await transport.send(GoogleOAuth.tokenRequest(clientId: clientId, redirectURI: redirectURI,
                                                                                 code: code, verifier: verifier))
        let token = try GoogleOAuth.parseTokenResponse(data: data, status: response.statusCode, now: Date(), previousRefreshToken: nil)
        try saveToken(try JSONEncoder().encode(token))
    }

    private func present(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let once = ResumeOnce(continuation)
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callbackURL, error in
                if let callbackURL {
                    once.resume(.success(callbackURL))
                } else {
                    once.resume(.failure(error ?? GoogleOAuthError.missingCode))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { once.resume(.failure(GoogleOAuthError.missingCode)) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }
}

/// Resumes a continuation at most once (the session may report both a start failure and a completion).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }

    func resume(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
