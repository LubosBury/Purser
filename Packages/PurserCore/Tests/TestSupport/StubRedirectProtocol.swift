import Foundation

/// The network of a URLSession in a test (set it as `protocolClasses`). A path under "/redirect/" is answered with a 307 to
/// "https://example.com/elsewhere/<rest>"; anything else with a 200 and three bytes. It records every URL it is asked to
/// load, so a test can show that a redirect was never followed. The 307 is also delivered as the response, which is what a
/// real connection does once the session refuses the redirect.
public final class StubRedirectProtocol: URLProtocol {
    private static let log = LoadedURLs()

    /// The URLs loaded so far that contain `token` (tests use a token of their own, because tests run in parallel).
    public static func loaded(containing token: String) -> [String] {
        log.urls.filter { $0.contains(token) }
    }

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        guard let url = request.url else { return }
        Self.log.add(url.absoluteString)
        if url.path.hasPrefix("/redirect/") {
            let rest = url.path.dropFirst("/redirect/".count)
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": "https://example.com/elsewhere/\(rest)"])!
            var next = URLRequest(url: URL(string: "https://example.com/elsewhere/\(rest)")!)
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("moved".utf8))
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override public func stopLoading() {}
}

private final class LoadedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var urls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func add(_ url: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(url)
    }
}
