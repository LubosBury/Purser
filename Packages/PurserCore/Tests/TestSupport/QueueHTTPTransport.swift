import Foundation
import ASCClient

/// HTTPTransport fake: returns queued responses in order and records every request.
public actor QueueHTTPTransport: HTTPTransport {
    public private(set) var requests: [URLRequest] = []
    private var responses: [(status: Int, body: Data)]

    public init(_ responses: [(status: Int, body: String)]) {
        self.responses = responses.map { ($0.status, Data($0.body.utf8)) }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.cannotConnectToHost) }
        let next = responses.removeFirst()
        return (next.body, HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
