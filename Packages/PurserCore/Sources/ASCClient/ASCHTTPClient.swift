import Foundation
import Domain
import PurserSecurity

public actor ASCHTTPClient {
    private let baseURL: URL
    private let transport: any HTTPTransport
    private let signer: JWTSigner
    private let budget: RateBudget
    private let readOnly: Bool
    private let now: @Sendable () -> Date
    public nonisolated let appGuard: AppGuard
    public private(set) var requestCount = 0

    /// Paging safety net: no ASC collection Purser reads comes near this many pages.
    static let maxPages = 500

    public init(baseURL: URL = URL(string: "https://api.appstoreconnect.apple.com")!,
                transport: any HTTPTransport, signer: JWTSigner, budget: RateBudget, appGuard: AppGuard,
                readOnly: Bool, now: @escaping @Sendable () -> Date) {
        self.baseURL = baseURL
        self.transport = transport
        self.signer = signer
        self.budget = budget
        self.appGuard = appGuard
        self.readOnly = readOnly
        self.now = now
    }

    /// GET with paging over `links.next`; read-only clients mint a GET-scoped token per request (T3-35).
    public func getAll(_ path: String, query: [URLQueryItem]) async throws -> [JSONAPIDocument] {
        var pages: [JSONAPIDocument] = []
        var url = try makeURL(path: path, query: query)
        while true {
            let page = try decode(try await perform(method: "GET", url: url, body: nil))
            pages.append(page)
            guard let next = page.nextURL else { return pages }
            guard next.host == baseURL.host, next.scheme == baseURL.scheme else {
                throw ASCError.foreignResource("links.next points to another host")
            }
            guard pages.count < Self.maxPages, next != url else {
                throw ASCError.decoding("Paging did not terminate for \(path)")
            }
            url = next
        }
    }

    public func get(_ path: String, query: [URLQueryItem]) async throws -> JSONAPIDocument {
        try decode(try await perform(method: "GET", url: try makeURL(path: path, query: query), body: nil))
    }

    /// POST/PATCH; nil for 204.
    public func send(method: String, path: String, body: Data) async throws -> JSONAPIDocument? {
        let data = try await perform(method: method, url: try makeURL(path: path, query: []), body: body)
        return data.isEmpty ? nil : try decode(data)
    }

    public func delete(path: String) async throws {
        _ = try await perform(method: "DELETE", url: try makeURL(path: path, query: []), body: nil)
    }

    #if DEBUG
    /// SpikeProbe only (K10): the same pipeline as `send`/`delete`/`get`, but returns the HTTP status and the raw body
    /// for every status instead of throwing `ASCError.http` / `.rateLimited`. `query` is the raw query without "?".
    package func sendRaw(method: String, path: String, query: String, body: Data?) async throws -> (status: Int, body: Data) {
        let url = try makeURL(path: path, query: Self.queryItems(raw: query))
        let (data, response) = try await exchange(method: method, url: url, body: body)
        return (status: response.statusCode, body: data)
    }
    #endif

    // MARK: - Internals

    /// K5 steps 1-8 up to the status check; `perform` adds the mapping of non-2xx statuses to ASCError.
    private func exchange(method: String, url: URL, body: Data?) async throws -> (Data, HTTPURLResponse) {
        // 1. A read-only client never sends anything but GET.
        if readOnly && method != "GET" { throw ASCError.readOnlyClient }
        // 2. Rule A9.
        try await appGuard.check(method: method, path: url.path, body: body)
        // 3. Only reads draw from the budget here; writes are paced by their caller (Executor, SpikeProbe).
        if method == "GET" { try await budget.acquire(forVerify: true) }

        // 4. A fresh token for every request (no cache): after a 401 the next request is signed again.
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let scope = readOnly ? [Self.scope(method: method, url: url)] : nil
        request.setValue("Bearer \(try signer.token(scope: scope, now: now(), jti: ASCRequestContext.tokenId ?? UUID().uuidString))",
                         forHTTPHeaderField: "Authorization")

        // 5. Count, send, record X-Rate-Limit.
        requestCount += 1
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch let error as ASCError {
            throw error
        } catch let error as URLError {
            // 7. Only the K5 list of URLError codes proves that nothing was sent.
            throw URLSessionTransport.map(error)
        } catch {
            throw ASCError.network(description: String(describing: error), maybeSent: true)
        }
        if let header = response.value(forHTTPHeaderField: "X-Rate-Limit"),
           let snapshot = RateLimitSnapshot.parse(header, at: now()) {
            await budget.record(snapshot)
        }
        // 6. Every resource of a 2xx JSON:API body belongs to the workspace app: let the guard know its id.
        if (200..<300).contains(response.statusCode), !data.isEmpty,
           let document = try? JSONDecoder().decode(JSONAPIDocument.self, from: data) {
            let ids = Set((document.data + document.included).map(\.id))
            if !ids.isEmpty { await appGuard.allowChildren(ids) }
        }
        // 8. Nothing is retried here: the Executor and the SyncEngine decide about retries and pauses.
        return (data, response)
    }

    private func perform(method: String, url: URL, body: Data?) async throws -> Data {
        let (data, response) = try await exchange(method: method, url: url, body: body)
        switch response.statusCode {
        case 200..<300:
            return data
        case 429:
            throw ASCError.rateLimited
        default:
            let first = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.errors.first
            throw ASCError.http(status: response.statusCode, code: first?.code, title: first?.title, detail: first?.detail)
        }
    }

    /// "a=1&b=x%2Cy" -> [a=1, b=x,y]; an empty string -> [].
    static func queryItems(raw: String) -> [URLQueryItem] {
        raw.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0].removingPercentEncoding ?? parts[0]
            let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : nil
            return URLQueryItem(name: name, value: value)
        }
    }

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard path.hasPrefix("/"), var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ASCError.foreignResource(path)
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ASCError.foreignResource(path) }
        return url
    }

    private func decode(_ data: Data) throws -> JSONAPIDocument {
        do {
            return try JSONDecoder().decode(JSONAPIDocument.self, from: data)
        } catch {
            throw ASCError.decoding(String(describing: error))
        }
    }

    /// "GET <path>?<query without limit, cursor and sort>", the form Purser puts into a scoped token.
    static func scope(method: String, url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = (components?.queryItems ?? []).filter { !["limit", "cursor", "sort"].contains($0.name) }
        let query = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return "\(method) \(url.path)" + (query.isEmpty ? "" : "?\(query)")
    }

    private struct ErrorBody: Decodable {
        struct Item: Decodable {
            let status: String?
            let code: String?
            let title: String?
            let detail: String?
        }
        let errors: [Item]
    }
}
