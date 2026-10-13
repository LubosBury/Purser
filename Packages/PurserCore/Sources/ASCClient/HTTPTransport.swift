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

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

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
