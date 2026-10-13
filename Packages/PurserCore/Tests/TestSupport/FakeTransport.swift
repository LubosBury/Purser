import Foundation
import Synchronization
import ASCClient

public struct FakeResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> FakeResponse {
        FakeResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    /// Tests/Fixtures/asc/<name>.json
    public static func fixture(_ name: String, status: Int = 200, headers: [String: String] = [:]) throws -> FakeResponse {
        FakeResponse(status: status, headers: headers, body: try Fixtures.asc(name))
    }

    public static func error(status: Int, code: String, title: String = "An error", detail: String = "Synthetic detail") -> FakeResponse {
        .json("{\"errors\":[{\"status\":\"\(status)\",\"code\":\"\(code)\",\"title\":\"\(title)\",\"detail\":\"\(detail)\"}]}", status: status)
    }
}

public struct RecordedRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public var path: String { url.path }
    public func queryValue(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

public enum FakeTransportError: Error, Equatable {
    case unrouted(String)
}

/// The single HTTP-level stub for ASC (spec §9 FakeASC): a route table of canned responses plus a log of requests.
/// A route matches on method, exact path and the listed query items; the most specific match wins,
/// and among equally specific routes the one added last wins.
/// A route with several responses returns them in order and then keeps repeating the last one.
public final class FakeTransport: HTTPTransport, Sendable {
    private struct Route: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        var responses: [FakeResponse]
    }

    private struct State: Sendable {
        var routes: [Route] = []
        var requests: [RecordedRequest] = []
        var failure: (any Error & Sendable)?
    }

    private let state = Mutex(State())

    public init() {}

    public func on(_ method: String, _ path: String, query: [String: String] = [:], _ responses: FakeResponse...) {
        state.withLock { $0.routes.append(Route(method: method, path: path, query: query, responses: responses)) }
    }

    /// Makes every following `send` throw `error` (simulates a transport failure).
    public func failAll(with error: any Error & Sendable) {
        state.withLock { $0.failure = error }
    }

    public var requests: [RecordedRequest] {
        state.withLock { $0.requests }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first })
        let response: FakeResponse = try state.withLock { state in
            state.requests.append(RecordedRequest(method: method, url: url, headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody))
            if let failure = state.failure { throw failure }
            let candidates = state.routes.indices.filter { index in
                let route = state.routes[index]
                return route.method == method && route.path == url.path && route.query.allSatisfy { query[$0.key] == $0.value }
            }
            // Most specific route wins; among equally specific routes the one added last wins (tests override defaults).
            guard let best = candidates.reversed().max(by: { state.routes[$0].query.count < state.routes[$1].query.count }) else {
                throw FakeTransportError.unrouted("\(method) \(url.absoluteString)")
            }
            if state.routes[best].responses.count > 1 {
                return state.routes[best].responses.removeFirst()
            }
            return state.routes[best].responses[0]
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }
}
