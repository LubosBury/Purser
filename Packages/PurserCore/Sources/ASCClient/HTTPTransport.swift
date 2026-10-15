import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum ASCError: Error, Equatable, Sendable {
    case http(status: Int, code: String?, title: String?, detail: String?)
    case rateLimited
    /// Transport failure. `maybeSent` is true when the request may have reached Apple.
    case network(description: String, maybeSent: Bool)
    case decoding(String)
    case foreignResource(String)
    case readOnlyClient
}

/// The transport for the ASC API (and the Slack webhook). It has a session of its own with an ephemeral configuration and no
/// URL cache, so no answer (texts, review notes, prices) is stored on disk in `URLCache.shared`; timeouts and the rest keep
/// the defaults of the shared session.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// A copy of the configuration of the session.
    var configuration: URLSessionConfiguration { session.configuration }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ASCError.network(description: "Response is not HTTP", maybeSent: true)
            }
            return (data, http)
        } catch let error as URLError {
            throw Self.map(error)
        }
    }

    /// Contract K5 step 7: the only codes that prove the request never left the Mac. Everything else
    /// (timeouts, lost connections, TLS and certificate failures, ...) may have reached Apple.
    static let neverSentCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed,
    ]

    static func map(_ error: URLError) -> ASCError {
        .network(description: "URLError \(error.code.rawValue): \(error.localizedDescription)",
                 maybeSent: !neverSentCodes.contains(error.code))
    }
}

/// The transport for Apple hosts other than the ASC API (the image CDN and the upload hosts). It has a session of its own
/// that keeps nothing between requests (no cookies, credentials or cache) and never follows a redirect: the 3xx comes back
/// as the response, so the request never reaches the host a redirect names. Errors are not mapped; the caller records their
/// domain and code.
public final class RedirectRefusingTransport: HTTPTransport {
    private let session: URLSession

    public convenience init() {
        self.init(protocolClasses: nil)
    }

    /// `protocolClasses` replaces the network of the session; tests pass a stub, the app passes nil.
    package init(protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// A copy of the configuration of the session.
    var configuration: URLSessionConfiguration { session.configuration }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Answers every redirect with "do not follow": the task then completes with the 3xx response itself.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
