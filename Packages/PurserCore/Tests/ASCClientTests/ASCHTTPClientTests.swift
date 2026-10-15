import Foundation
import Testing
import ASCClient
import Domain
import PurserSecurity
import PurserTestSupport

/// Answers every request with `status` and `body` from the URL `moved` gives for the request's URL, as a session that
/// followed a redirect would; records every request it got.
private final class MovedAnswerTransport: HTTPTransport, Sendable {
    let status: Int
    let body: String
    let moved: @Sendable (URL) -> URL
    let requests = Locked<[URLRequest]>([])

    init(status: Int = 200, body: String, moved: @escaping @Sendable (URL) -> URL) {
        self.status = status; self.body = body; self.moved = moved
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.update { $0.append(request) }
        let url = moved(request.url!)
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private func replacing(_ url: URL, scheme: String? = nil, host: String? = nil, path: String? = nil) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    if let scheme { components.scheme = scheme }
    if let host { components.host = host }
    if let path { components.path = path }
    return components.url!
}

@Suite struct ASCHTTPClientTests {
    private let base = "https://api.appstoreconnect.apple.com"

    private func makeClient(_ transport: any HTTPTransport, readOnly: Bool = true) throws -> (ASCHTTPClient, RateBudget) {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_791_547_200))
        let signer = try JWTSigner(keyId: "ABCDEF1234", identity: .team(issuerId: "issuer-1"), privateKeyPEM: TestKeys.makeKey().pem)
        let budget = RateBudget(now: { clock.now() }, sleep: { try await clock.sleep($0) })
        let appGuard = AppGuard(appId: "6400000001")
        let client = ASCHTTPClient(transport: transport, signer: signer, budget: budget, appGuard: appGuard,
                                   readOnly: readOnly, now: { clock.now() })
        return (client, budget)
    }

    @Test func readOnlyClientSendsAGetScopedBearerToken() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/territories", .json(#"{"data":[{"type":"territories","id":"USA","attributes":{"currency":"USD"}}]}"#))
        let (client, _) = try makeClient(transport)
        let document = try await client.get("/v1/territories", query: [URLQueryItem(name: "limit", value: "200")])
        #expect(document.data.map(\.id) == ["USA"])

        let request = try #require(transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.queryValue("limit") == "200")
        let authorization = try #require(request.headers["Authorization"])
        #expect(authorization.hasPrefix("Bearer "))
        let claims = try #require(TestKeys.claims(of: String(authorization.dropFirst("Bearer ".count))))
        #expect(claims["scope"] as? [String] == ["GET /v1/territories"])
        #expect(await client.requestCount == 1)
    }

    @Test func scopeKeepsFiltersAndIncludesButDropsPaging() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/apps/6400000001/subscriptionGroups", .json(#"{"data":[]}"#))
        let (client, _) = try makeClient(transport)
        _ = try await client.get("/v1/apps/6400000001/subscriptionGroups", query: [
            URLQueryItem(name: "filter[referenceName]", value: "Fruit"),
            URLQueryItem(name: "sort", value: "referenceName"),
            URLQueryItem(name: "limit", value: "200"),
        ])
        let authorization = try #require(transport.requests.first?.headers["Authorization"])
        let claims = try #require(TestKeys.claims(of: String(authorization.dropFirst("Bearer ".count))))
        #expect(claims["scope"] as? [String] == ["GET /v1/apps/6400000001/subscriptionGroups?filter[referenceName]=Fruit"])
    }

    @Test func followsNextLinksAcrossPages() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/territories", .json("""
            {"data":[{"type":"territories","id":"USA","attributes":{"currency":"USD"}}],
             "links":{"next":"\(base)/v1/territories?cursor=Mg&limit=1"},"meta":{"paging":{"total":2,"limit":1}}}
            """))
        transport.on("GET", "/v1/territories", query: ["cursor": "Mg"], .json("""
            {"data":[{"type":"territories","id":"CZE","attributes":{"currency":"CZK"}}],"meta":{"paging":{"total":2,"limit":1}}}
            """))
        let (client, _) = try makeClient(transport)
        let pages = try await client.getAll("/v1/territories", query: [URLQueryItem(name: "limit", value: "1")])
        #expect(pages.flatMap(\.data).map(\.id) == ["USA", "CZE"])
        #expect(pages.first?.total == 2)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].queryValue("cursor") == "Mg")
        let scopes = transport.requests.compactMap { TestKeys.claims(of: String($0.headers["Authorization"]!.dropFirst(7)))?["scope"] as? [String] }
        #expect(scopes == [["GET /v1/territories"], ["GET /v1/territories"]])
    }

    @Test func refusesNextLinksToAnotherHost() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/territories", .json(#"{"data":[],"links":{"next":"https://evil.example.com/v1/territories?cursor=x"}}"#))
        let (client, _) = try makeClient(transport)
        await #expect(throws: ASCError.foreignResource("links.next points to another host")) {
            _ = try await client.getAll("/v1/territories", query: [])
        }
        #expect(transport.requests.count == 1)
    }

    @Test func decodesASCErrorBodies() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/apps/6400000001", .error(status: 403, code: "FORBIDDEN_ERROR", title: "Forbidden", detail: "No access"))
        let (client, _) = try makeClient(transport)
        await #expect(throws: ASCError.http(status: 403, code: "FORBIDDEN_ERROR", title: "Forbidden", detail: "No access")) {
            _ = try await client.get("/v1/apps/6400000001", query: [])
        }
    }

    @Test func mapsTooManyRequestsToRateLimited() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/apps/6400000001", .error(status: 429, code: "RATE_LIMIT_EXCEEDED"))
        let (client, _) = try makeClient(transport)
        await #expect(throws: ASCError.rateLimited) { _ = try await client.get("/v1/apps/6400000001", query: []) }
    }

    @Test func recordsTheRateLimitHeader() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/apps/6400000001", .json(#"{"data":{"type":"apps","id":"6400000001","attributes":{}}}"#,
                                                         headers: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:3499;"]))
        let (client, budget) = try makeClient(transport)
        _ = try await client.get("/v1/apps/6400000001", query: [])
        #expect(await budget.latest?.remaining == 3499)
        #expect(await budget.latest?.limit == 3500)
    }

    @Test func readOnlyClientRefusesEveryNonGetBeforeSending() async throws {
        let transport = FakeTransport()
        let (client, _) = try makeClient(transport)
        await #expect(throws: ASCError.readOnlyClient) {
            _ = try await client.send(method: "POST", path: "/v1/subscriptionPrices", body: Data("{}".utf8))
        }
        await #expect(throws: ASCError.readOnlyClient) {
            _ = try await client.send(method: "PATCH", path: "/v1/subscriptionIntroductoryOffers/intro-1", body: Data("{}".utf8))
        }
        await #expect(throws: ASCError.readOnlyClient) { try await client.delete(path: "/v1/subscriptionPrices/price-1") }
        await #expect(throws: ASCError.readOnlyClient) {
            _ = try await client.sendRaw(method: "DELETE", path: "/v1/subscriptionPrices/price-1", query: "", body: nil)
        }
        #expect(transport.requests.isEmpty)
        #expect(await client.requestCount == 0)
    }

    @Test func writeClientUsesAnUnscopedTokenAndReturnsNilFor204() async throws {
        let transport = FakeTransport()
        transport.on("DELETE", "/v1/subscriptionPrices/price-1", FakeResponse(status: 204, body: Data()))
        let (client, _) = try makeClient(transport, readOnly: false)
        await client.appGuard.allowChildren(["price-1"])
        try await client.delete(path: "/v1/subscriptionPrices/price-1")
        let authorization = try #require(transport.requests.first?.headers["Authorization"])
        let claims = try #require(TestKeys.claims(of: String(authorization.dropFirst(7))))
        #expect(claims["scope"] == nil)
    }

    @Test func appGuardRunsBeforeAnythingIsSent() async throws {
        let transport = FakeTransport()
        let (client, _) = try makeClient(transport)
        await #expect(throws: ASCError.foreignResource("/v1/apps/6400000002")) {
            _ = try await client.get("/v1/apps/6400000002", query: [])
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func wrapsUnknownTransportErrorsAsMaybeSent() async throws {
        struct Boom: Error {}
        let transport = FakeTransport()
        transport.failAll(with: Boom())
        let (client, _) = try makeClient(transport)
        do {
            _ = try await client.get("/v1/territories", query: [])
            Issue.record("expected a throw")
        } catch let ASCError.network(_, maybeSent) {
            #expect(maybeSent)
        }
    }

    @Test func onlyGetsAcquireTheBudget() async throws {
        let transport = FakeTransport()
        transport.on("DELETE", "/v1/subscriptionPrices/price-1", FakeResponse(status: 204, body: Data()))
        let (client, budget) = try makeClient(transport, readOnly: false)
        // Nothing left of the hourly budget: a GET (verify share) is refused before sending ...
        await budget.record(RateLimitSnapshot(limit: 3500, remaining: 0, observedAt: Date(timeIntervalSince1970: 1_791_547_200)))
        await #expect(throws: ASCError.rateLimited) { _ = try await client.get("/v1/territories", query: []) }
        #expect(transport.requests.isEmpty)
        // ... while a write never calls acquire: the Executor and SpikeProbe pace writes themselves (K5 step 3).
        await client.appGuard.allowChildren(["price-1"])
        try await client.delete(path: "/v1/subscriptionPrices/price-1")
        #expect(transport.requests.map(\.method) == ["DELETE"])
        #expect(await client.requestCount == 1)
    }

    @Test func registersEveryReturnedIdAsAChild() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/apps/6400000001/subscriptionGroups",
                     .json(#"{"data":[{"type":"subscriptionGroups","id":"7000000001"}],"included":[{"type":"subscriptionGroupLocalizations","id":"loc-1"}]}"#))
        transport.on("GET", "/v1/subscriptionGroups/7000000001/subscriptions", .json(#"{"data":[]}"#))
        transport.on("POST", "/v1/subscriptionPrices", .json(#"{"data":{"type":"subscriptionPrices","id":"price-new"}}"#, status: 201))
        transport.on("DELETE", "/v1/subscriptionPrices/price-new", FakeResponse(status: 204, body: Data()))
        let (client, _) = try makeClient(transport, readOnly: false)
        _ = try await client.get("/v1/apps/6400000001/subscriptionGroups", query: [])
        // Without step 6 of K5 the guard would refuse the group id here.
        _ = try await client.get("/v1/subscriptionGroups/7000000001/subscriptions", query: [])
        try await client.appGuard.check(method: "GET", path: "/v1/subscriptionGroups/loc-1", body: nil)

        await client.appGuard.allowProducts(["6500000001"])
        let body = Data(#"{"data":{"type":"subscriptionPrices","relationships":{"subscription":{"data":{"type":"subscriptions","id":"6500000001"}}}}}"#.utf8)
        let created = try await client.send(method: "POST", path: "/v1/subscriptionPrices", body: body)
        #expect(created?.data.first?.id == "price-new")
        try await client.delete(path: "/v1/subscriptionPrices/price-new")
        #expect(transport.requests.map(\.method) == ["GET", "GET", "POST", "DELETE"])
    }

    @Test func neverRetriesAndMapsURLErrors() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/territories", .error(status: 500, code: "UNEXPECTED_ERROR"))
        let (client, _) = try makeClient(transport)
        await #expect(throws: ASCError.http(status: 500, code: "UNEXPECTED_ERROR", title: "An error", detail: "Synthetic detail")) {
            _ = try await client.get("/v1/territories", query: [])
        }
        #expect(transport.requests.count == 1)

        transport.failAll(with: URLError(.notConnectedToInternet))
        do {
            _ = try await client.get("/v1/territories", query: [])
            Issue.record("expected a throw")
        } catch let ASCError.network(_, maybeSent) {
            #expect(maybeSent == false)
        }
        transport.failAll(with: URLError(.timedOut))
        do {
            _ = try await client.get("/v1/territories", query: [])
            Issue.record("expected a throw")
        } catch let ASCError.network(_, maybeSent) {
            #expect(maybeSent == true)
        }
        #expect(transport.requests.count == 3)
        #expect(await client.requestCount == 3)
    }

    @Test func sendRawReturnsStatusAndBodyForEveryStatus() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/v1/subscriptionPrices", .error(status: 409, code: "ENTITY_ERROR.ATTRIBUTE.INVALID"))
        transport.on("PATCH", "/v1/subscriptionIntroductoryOffers/intro-1", .error(status: 429, code: "RATE_LIMIT_EXCEEDED"))
        transport.on("GET", "/v1/subscriptions/6500000001/prices", query: ["limit": "200"],
                     .json(#"{"data":[{"type":"subscriptionPrices","id":"price-9"}]}"#))
        let (client, _) = try makeClient(transport, readOnly: false)
        await client.appGuard.allowProducts(["6500000001"])
        await client.appGuard.allowChildren(["intro-1"])

        let body = Data(#"{"data":{"type":"subscriptionPrices","relationships":{"subscription":{"data":{"type":"subscriptions","id":"6500000001"}}}}}"#.utf8)
        let conflict = try await client.sendRaw(method: "POST", path: "/v1/subscriptionPrices", query: "", body: body)
        #expect(conflict.status == 409)
        #expect(String(decoding: conflict.body, as: UTF8.self).contains("ENTITY_ERROR.ATTRIBUTE.INVALID"))
        let limited = try await client.sendRaw(method: "PATCH", path: "/v1/subscriptionIntroductoryOffers/intro-1", query: "", body: Data("{}".utf8))
        #expect(limited.status == 429)

        let read = try await client.sendRaw(method: "GET", path: "/v1/subscriptions/6500000001/prices",
                                            query: "limit=200&include=territory", body: nil)
        #expect(read.status == 200)
        #expect(transport.requests.last?.queryValue("include") == "territory")
        // The id of the 2xx response is now a child the guard lets through (K5 step 6).
        try await client.appGuard.check(method: "DELETE", path: "/v1/subscriptionPrices/price-9", body: nil)
        #expect(transport.requests.first?.headers["Authorization"]?.hasPrefix("Bearer ") == true)
        #expect(await client.requestCount == 3)
    }

    // MARK: - Cached and redirected answers

    @Test func everyRequestAsksForAFreshAnswerNeverACachedOne() async throws {
        let transport = MovedAnswerTransport(body: #"{"data":[]}"#) { $0 }
        let (client, _) = try makeClient(transport, readOnly: false)
        _ = try await client.get("/v1/territories", query: [])
        await client.appGuard.allowProducts(["6500000001"])
        let body = Data(#"{"data":{"type":"subscriptionPrices","relationships":{"subscription":{"data":{"type":"subscriptions","id":"6500000001"}}}}}"#.utf8)
        _ = try await client.send(method: "POST", path: "/v1/subscriptionPrices", body: body)
        await client.appGuard.allowChildren(["price-1"])
        try await client.delete(path: "/v1/subscriptionPrices/price-1")
        let policies = transport.requests.value.map(\.cachePolicy)
        #expect(policies == Array(repeating: .reloadIgnoringLocalAndRemoteCacheData, count: 3))
    }

    @Test(arguments: [("host", "https", "api.example.com", "/v1/apps/6400000001/subscriptionGroups"),
                      ("scheme", "http", "api.appstoreconnect.apple.com", "/v1/apps/6400000001/subscriptionGroups"),
                      ("path", "https", "api.appstoreconnect.apple.com", "/v1/apps/6400000001/inAppPurchasesV2")])
    func aReadAnsweredFromAnotherURLIsRefusedBeforeItsIdsAreLearned(changed: String, scheme: String, host: String, path: String) async throws {
        let transport = MovedAnswerTransport(body: #"{"data":[{"type":"subscriptionGroups","id":"7000000009"}]}"#) { url in
            replacing(url, scheme: scheme, host: host, path: path)
        }
        let (client, _) = try makeClient(transport)
        await #expect(throws: ASCError.network(description: "answer from another URL", maybeSent: true), "another \(changed)") {
            _ = try await client.get("/v1/apps/6400000001/subscriptionGroups", query: [URLQueryItem(name: "limit", value: "200")])
        }
        await #expect(throws: ASCError.foreignResource("/v1/subscriptionGroups/7000000009")) {
            try await client.appGuard.check(method: "GET", path: "/v1/subscriptionGroups/7000000009", body: nil)
        }
        #expect(transport.requests.value.count == 1)
    }

    @Test func aWriteAnsweredFromAnotherURLIsMaybeSentAndItsIdIsNotLearned() async throws {
        let transport = MovedAnswerTransport(status: 201, body: #"{"data":{"type":"subscriptionPrices","id":"price-new"}}"#) { url in
            replacing(url, path: "/v1/subscriptionPrices/elsewhere")
        }
        let (client, _) = try makeClient(transport, readOnly: false)
        await client.appGuard.allowProducts(["6500000001"])
        let body = Data(#"{"data":{"type":"subscriptionPrices","relationships":{"subscription":{"data":{"type":"subscriptions","id":"6500000001"}}}}}"#.utf8)
        await #expect(throws: ASCError.network(description: "answer from another URL", maybeSent: true)) {
            _ = try await client.send(method: "POST", path: "/v1/subscriptionPrices", body: body)
        }
        await #expect(throws: ASCError.foreignResource("/v1/subscriptionPrices/price-new")) {
            try await client.appGuard.check(method: "DELETE", path: "/v1/subscriptionPrices/price-new", body: nil)
        }
    }

    @Test func anAnswerFromTheSameURLWithAnotherQueryIsAccepted() async throws {
        let transport = MovedAnswerTransport(body: #"{"data":[{"type":"territories","id":"USA","attributes":{"currency":"USD"}}]}"#) { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "50")]
            return components.url!
        }
        let (client, _) = try makeClient(transport)
        let document = try await client.get("/v1/territories", query: [URLQueryItem(name: "limit", value: "200")])
        #expect(document.data.map(\.id) == ["USA"])
    }
}
