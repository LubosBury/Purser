import Foundation
import Testing
import Domain
import ASCClient
import PurserSecurity
import PurserTestSupport

private func clients(_ fake: FakeASC, _ clock: TestClock) async throws -> (reader: LiveASCClient, writer: LiveASCClient) {
    let model = await fake.model
    let products = Set(model.subscriptions.map(\.id) + model.iaps.map(\.id))
    let children = Set(model.regularPrices.map(\.id) + model.intros.map(\.id) + model.promos.map(\.id) + model.iapSchedules.map(\.id))
    let read = try await WriteTestClients.http(transport: fake, readOnly: true, products: products, children: children, now: clock.nowFunction)
    let write = try await WriteTestClients.http(transport: fake, readOnly: false, products: products, children: children, now: clock.nowFunction)
    return (LiveASCClient(http: read), LiveASCClient(http: write))
}

private func ascError(_ body: () async throws -> Void) async -> ASCError? {
    do { try await body(); return nil } catch let error as ASCError { return error } catch { return nil }
}

private func detail(_ error: ASCError?) -> String {
    if case let .http(_, code, title, detail)? = error { return [code, title, detail].compactMap { $0 }.joined(separator: " ") }
    return ""
}

/// A real ES256 token with a throwaway key (FakeASC checks the shape, not the signature).
private func bearer(identity: JWTIdentity = WriteTestClients.teamIdentity) throws -> String {
    "Bearer " + (try WriteTestClients.signer(identity: identity).token(scope: nil, now: Date()))
}

private func raw(_ fake: FakeASC, _ method: String, _ path: String, body: String? = nil,
                 authorization: String? = nil) async throws -> (status: Int, data: Data, response: HTTPURLResponse) {
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com\(path)")!)
    request.httpMethod = method
    request.httpBody = body.map { Data($0.utf8) }
    request.setValue(try authorization ?? bearer(), forHTTPHeaderField: "Authorization")
    let (data, response) = try await fake.send(request)
    return (response.statusCode, data, response)
}

/// One base64url JWT segment (for hand-made invalid tokens).
private func segment(_ object: [String: Any]) throws -> String {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func day(_ iso: String) -> CalendarDate { CalendarDate(iso: iso)! }

@Suite("FakeASC")
struct FakeASCTests {
    let clock = TestClock.at("2026-10-09T08:00:00Z")

    func makeFake() -> FakeASC { FakeASC(model: FakeSeed.fruitJar(), now: clock.nowFunction) }

    @Test func servesEveryReadFromItsModel() async throws {
        let fake = makeFake()
        let (reader, _) = try await clients(fake, clock)
        #expect(try await reader.app(id: FakeSeed.appId).bundleId == "com.example.fruitjar")
        #expect(try await reader.territories().count == 6)
        let groups = try await reader.subscriptionGroups(appId: FakeSeed.appId)
        #expect(groups.map(\.id) == ["grp-1"])
        let subs = try await reader.subscriptions(group: groups[0])
        #expect(Set(subs.map(\.ascId)) == ["sub-y", "sub-m", "sub-n"])
        let yearly = try #require(subs.first { $0.ascId == "sub-y" })
        #expect(yearly.state == .approved)
        #expect(yearly.availableTerritories.count == 6)
        let prices = try await reader.regularPrices(subscription: yearly)
        #expect(prices.count == 6)
        #expect(prices.first { $0.territory == "CZE" }?.customerPrice == Decimal(string: "9.99"))
        #expect(prices.allSatisfy { $0.planType == .upfront && $0.startDate == FakeSeed.seedStart })
        #expect(try await reader.introductoryOffers(subscription: yearly).isEmpty)
        #expect(try await reader.promotionalOffers(subscription: yearly).isEmpty)
        #expect(try await reader.pricePoints(subscriptionId: "sub-y", territories: ["CZE"], planType: .upfront).count == 40)
        #expect(try await reader.inAppPurchases(appId: FakeSeed.appId).map(\.ascId) == ["iap-life"])
        let schedule = try #require(try await reader.iapPriceSchedule(iapId: "iap-life"))
        #expect(schedule.baseTerritory == "USA")
        #expect(schedule.manualPrices.map(\.pricePointId) == ["pp-iap-life-USA-29"])
        #expect(try await reader.iapPricePoints(iapId: "iap-life", territories: ["USA"]).count == 60)
    }

    @Test func pagesWithLinksNext() async throws {
        let fake = makeFake()
        let first = try await raw(fake, "GET", "/v1/subscriptions/sub-y/prices?limit=4")
        let document = try json(first.data)
        #expect((document["data"] as? [Any])?.count == 4)
        let next = try #require((document["links"] as? [String: Any])?["next"] as? String)
        #expect(next.contains("cursor=4"))
        let second = try await raw(fake, "GET", "/v1/subscriptions/sub-y/prices?limit=4&cursor=4")
        #expect((try json(second.data)["data"] as? [Any])?.count == 2)
    }

    @Test func secondFutureRegularChangeIsRejected() async throws {
        let fake = makeFake()
        let (_, writer) = try await clients(fake, clock)
        _ = try await writer.createRegularPrice(NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront,
                                                                pricePointId: "pp-sub-y-CZE-12", startDate: day("2026-11-01"), preserveCurrentPrice: true))
        let error = await ascError {
            _ = try await writer.createRegularPrice(NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront,
                                                                    pricePointId: "pp-sub-y-CZE-13", startDate: day("2026-11-15"), preserveCurrentPrice: true))
        }
        #expect(detail(error).contains("Must delete future price change"))
        #expect(await fake.model.regularPrices.filter { $0.subscriptionId == "sub-y" && $0.territory == "CZE" }.count == 2)
    }

    @Test func deleteInsideCutoffIsRejectedAndFarFutureDeleteWorks() async throws {
        let fake = makeFake()
        let (_, writer) = try await clients(fake, clock)
        let near = try await writer.createRegularPrice(NewRegularPrice(subscriptionId: "sub-m", territory: "CZE", planType: .upfront,
                                                                       pricePointId: "pp-sub-m-CZE-3", startDate: day("2026-10-10"), preserveCurrentPrice: false))
        let nearError = await ascError { try await writer.deleteRegularPrice(ascId: near.ascId) }
        #expect(detail(nearError).contains("Only future price changes can be deleted"))
        let currentError = await ascError { try await writer.deleteRegularPrice(ascId: "price-sub-m-DEU-0") }
        #expect(detail(currentError).contains("Only future price changes can be deleted"))
        let far = try await writer.createRegularPrice(NewRegularPrice(subscriptionId: "sub-m", territory: "DEU", planType: .upfront,
                                                                      pricePointId: "pp-sub-m-DEU-3", startDate: day("2026-10-20"), preserveCurrentPrice: false))
        try await writer.deleteRegularPrice(ascId: far.ascId)
        #expect(await fake.model.regularPrices.contains { $0.id == far.ascId } == false)
    }

    @Test func introWithoutTerritoryIsRejected() async throws {
        let fake = makeFake()
        let reply = try await raw(fake, "POST", "/v1/subscriptionIntroductoryOffers", body: """
        {"data":{"type":"subscriptionIntroductoryOffers",
          "attributes":{"duration":"ONE_WEEK","offerMode":"FREE_TRIAL","numberOfPeriods":1},
          "relationships":{"subscription":{"data":{"type":"subscriptions","id":"sub-n"}}}}}
        """)
        #expect(reply.status == 409)
        let errors = try #require(try json(reply.data)["errors"] as? [[String: Any]])
        #expect(errors.first?["code"] as? String == "ENTITY_ERROR.RELATIONSHIP.REQUIRED")
        #expect(await fake.model.intros.isEmpty)
    }

    @Test func introAllowsOneCurrentAndOneFutureWithoutOverlap() async throws {
        let fake = makeFake()
        let (_, writer) = try await clients(fake, clock)
        func trial(_ start: String?) -> NewIntroOffer {
            NewIntroOffer(subscriptionId: "sub-n", territory: "USA", planType: .upfront, mode: .freeTrial, duration: .oneWeek,
                          numberOfPeriods: 1, startDate: start.map(day), endDate: nil, pricePointId: nil)
        }
        let current = try await writer.createIntroductoryOffer(trial(nil))
        let overlap = await ascError { _ = try await writer.createIntroductoryOffer(trial("2026-11-01")) }
        #expect(detail(overlap).contains("overlaps"))
        try await writer.endIntroductoryOffer(ascId: current.ascId, endDate: day("2026-11-01"))
        _ = try await writer.createIntroductoryOffer(trial("2026-11-01"))
        let third = await ascError { _ = try await writer.createIntroductoryOffer(trial("2026-12-01")) }
        #expect(detail(third).contains("one current and one future"))
        #expect(await fake.model.intros.count == 2)
    }

    @Test func offerCodesAreBurnedAndMaxTenPromos() async throws {
        let fake = makeFake()
        let (_, writer) = try await clients(fake, clock)
        func promo(_ code: String) -> NewPromoOffer {
            NewPromoOffer(subscriptionId: "sub-y", offerCode: code, name: code, mode: .freeTrial, duration: .oneMonth,
                          numberOfPeriods: 1, planType: .upfront, prices: [NewPromoPrice(territory: "USA", pricePointId: nil)])
        }
        let first = try await writer.createPromotionalOffer(promo("spring_v1"))
        try await writer.deletePromotionalOffer(ascId: first.ascId)
        let reuse = await ascError { _ = try await writer.createPromotionalOffer(promo("spring_v1")) }
        #expect(detail(reuse).contains(FakeASC.offerCodeReuseError.detail))
        for i in 1...10 { _ = try await writer.createPromotionalOffer(promo("c_v\(i)")) }
        let eleventh = await ascError { _ = try await writer.createPromotionalOffer(promo("c_v11")) }
        #expect(detail(eleventh).contains("maximum number of promotional offers"))
    }

    @Test func rateLimitHeaderCountsDownAndEmptyBudgetReturns429() async throws {
        let fake = makeFake()
        await fake.setRateBudget(limit: 5, remaining: 2)
        let a = try await raw(fake, "GET", "/v1/territories")
        #expect(a.response.value(forHTTPHeaderField: "X-Rate-Limit") == "user-hour-lim:5;user-hour-rem:1;")
        let b = try await raw(fake, "GET", "/v1/territories")
        #expect(b.response.value(forHTTPHeaderField: "X-Rate-Limit") == "user-hour-lim:5;user-hour-rem:0;")
        let c = try await raw(fake, "GET", "/v1/territories")
        #expect(c.status == 429)
    }

    @Test func injectedFaultsBehaveAsDocumented() async throws {
        let fake = makeFake()
        let (_, writer) = try await clients(fake, clock)
        func intro(_ territory: TerritoryCode) -> NewIntroOffer {
            NewIntroOffer(subscriptionId: "sub-n", territory: territory, planType: .upfront, mode: .freeTrial, duration: .oneWeek,
                          numberOfPeriods: 1, startDate: day("2026-11-01"), endDate: nil, pricePointId: nil)
        }
        await fake.inject(.rateLimited, times: 2)
        #expect(await ascError { _ = try await writer.createIntroductoryOffer(intro("USA")) } == .rateLimited)
        #expect(await ascError { _ = try await writer.createIntroductoryOffer(intro("USA")) } == .rateLimited)
        _ = try await writer.createIntroductoryOffer(intro("USA"))
        #expect(await fake.model.intros.count == 1)

        await fake.inject(.timeoutAfterApply)
        let timeout = await ascError { _ = try await writer.createIntroductoryOffer(intro("CZE")) }
        if case let .network(_, maybeSent)? = timeout { #expect(maybeSent) } else { Issue.record("expected network error, got \(String(describing: timeout))") }
        #expect(await fake.model.intros.count == 2)
        #expect(await fake.writeRequests().last?.applied == true)

        await fake.inject(.networkBeforeSend)
        let offline = await ascError { _ = try await writer.createIntroductoryOffer(intro("DEU")) }
        if case let .network(_, maybeSent)? = offline { #expect(!maybeSent) } else { Issue.record("expected network error") }
        #expect(await fake.model.intros.count == 2)

        await fake.inject(.serverError(status: 500, applyFirst: true))
        let server = await ascError { _ = try await writer.createIntroductoryOffer(intro("FRA")) }
        if case let .http(status, _, _, _)? = server { #expect(status == 500) } else { Issue.record("expected 500") }
        #expect(await fake.model.intros.count == 3)

        await fake.inject(.pricingNotAllowed)
        #expect(detail(await ascError { _ = try await writer.createIntroductoryOffer(intro("GBR")) }).contains("Pricing change is not allowed"))
        await fake.inject(.agreementMissing403)
        #expect(detail(await ascError { _ = try await writer.createIntroductoryOffer(intro("GBR")) }).contains("REQUIRED_AGREEMENTS"))
        #expect(await fake.model.intros.count == 3)
    }

    @Test func requestLogKeepsOnlyAuthorizationPresence() async throws {
        let fake = makeFake()
        let (reader, _) = try await clients(fake, clock)
        _ = try await reader.territories()
        let log = await fake.requests()
        #expect(!log.isEmpty)
        #expect(log.allSatisfy { $0.hadAuthorization })
        #expect(!String(describing: log).contains("Bearer"))
    }

    @Test func acceptsBothTokenShapesAndRejectsAnyOther() async throws {
        let fake = makeFake()
        #expect(try await raw(fake, "GET", "/v1/territories").status == 200)
        #expect(try await raw(fake, "GET", "/v1/territories", authorization: try bearer(identity: .individual)).status == 200)
        #expect(try await raw(fake, "GET", "/v1/territories", authorization: "Bearer test-token").status == 401)
        let header = try segment(["alg": "ES256", "kid": "TESTKEY001", "typ": "JWT"])
        let longLived = try segment(["iss": "issuer", "iat": 1_790_000_000, "exp": 1_790_003_600, "aud": "appstoreconnect-v1"])
        let bothShapes = try segment(["iss": "issuer", "sub": "user", "iat": 1_790_000_000, "exp": 1_790_000_600, "aud": "appstoreconnect-v1"])
        #expect(try await raw(fake, "GET", "/v1/territories", authorization: "Bearer \(header).\(longLived).c2ln").status == 401)
        #expect(try await raw(fake, "GET", "/v1/territories", authorization: "Bearer \(header).\(bothShapes).c2ln").status == 401)
        let log = await fake.requests()
        let identities = log.map { $0.identity }
        #expect(identities == ["team", "individual", nil, nil, nil])
        #expect(log[0].tokenId?.count == 36)
    }

    @Test func duplicatesAreDetected() async throws {
        let fake = makeFake()
        #expect(await fake.duplicates().isEmpty)
        await fake.mutate { model in
            var copy = model.regularPrices[0]
            copy.id = "price-copy"
            model.regularPrices.append(copy)
        }
        #expect(await fake.duplicates().count == 1)
    }
}
