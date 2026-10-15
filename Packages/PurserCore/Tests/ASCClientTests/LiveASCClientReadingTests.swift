import Foundation
import Testing
import ASCClient
import Domain
import PurserSecurity
import PurserTestSupport

@Suite struct LiveASCClientReadingTests {
    /// Routes every K5 read endpoint of the synthetic "Fruit Journal" app to its hand-made fixture.
    static func routedTransport() throws -> FakeTransport {
        let t = FakeTransport()
        t.on("GET", "/v1/apps/6400000001", try .fixture("app"))
        t.on("GET", "/v1/territories", try .fixture("territories"))
        t.on("GET", "/v1/apps/6400000001/subscriptionGroups", try .fixture("subscriptionGroups"))
        t.on("GET", "/v1/subscriptionGroups/7000000001/subscriptions", try .fixture("subscriptions"))
        for id in ["6500000001", "6500000002"] {
            t.on("GET", "/v1/subscriptions/\(id)/subscriptionAvailability", try .fixture("subscriptionAvailability-\(id)"))
            t.on("GET", "/v1/subscriptionAvailabilities/av-\(id)/availableTerritories", try .fixture("availableTerritories-\(id)"))
            t.on("GET", "/v1/subscriptions/\(id)/planAvailabilities", try .fixture("planAvailabilities-\(id)"))
        }
        t.on("GET", "/v1/subscriptions/6500000001/prices", try .fixture("subscriptionPrices"))
        t.on("GET", "/v1/subscriptions/6500000001/introductoryOffers", try .fixture("introductoryOffers"))
        t.on("GET", "/v1/subscriptions/6500000001/promotionalOffers", try .fixture("promotionalOffers"))
        t.on("GET", "/v1/subscriptionPromotionalOffers/promo-1/prices", try .fixture("promotionalOfferPrices"))
        t.on("GET", "/v1/subscriptions/6500000001/pricePoints", try .fixture("subscriptionPricePoints"))
        t.on("GET", "/v1/apps/6400000001/inAppPurchasesV2", try .fixture("inAppPurchasesV2"))
        t.on("GET", "/v2/inAppPurchases/6600000001/iapPriceSchedule", try .fixture("iapPriceSchedule"))
        t.on("GET", "/v1/inAppPurchasePriceSchedules/6600000001/baseTerritory", try .fixture("iapBaseTerritory"))
        t.on("GET", "/v1/inAppPurchasePriceSchedules/6600000001/manualPrices", try .fixture("iapManualPrices"))
        t.on("GET", "/v2/inAppPurchases/6600000001/pricePoints", try .fixture("iapPricePoints"))
        return t
    }

    static func makeClient(_ transport: FakeTransport) throws -> LiveASCClient {
        let clock = ManualClock(Sample.fixedNow)
        let signer = try JWTSigner(keyId: "ABCDEF1234", identity: .team(issuerId: "issuer-1"), privateKeyPEM: TestKeys.makeKey().pem)
        let http = ASCHTTPClient(transport: transport, signer: signer,
                                 budget: RateBudget(now: { clock.now() }, sleep: { try await clock.sleep($0) }),
                                 appGuard: AppGuard(appId: "6400000001"), readOnly: true, now: { clock.now() })
        return LiveASCClient(http: http)
    }

    private func yearly(_ client: LiveASCClient) async throws -> SubscriptionInfo {
        let group = try #require(try await client.subscriptionGroups(appId: "6400000001").first)
        return try #require(try await client.subscriptions(group: group).first { $0.ascId == "6500000001" })
    }

    @Test func readsAppAndTerritories() async throws {
        let client = try Self.makeClient(try Self.routedTransport())
        #expect(try await client.app(id: "6400000001") == ASCApp(id: "6400000001", bundleId: "com.example.fruitjournal", name: "Fruit Journal"))
        let territories = try await client.territories()
        // Spike S0 replaces territories.json with the full recorded list; the test holds for both versions.
        let fixture = try JSONSerialization.jsonObject(with: try Fixtures.asc("territories")) as? [String: Any]
        #expect(territories.count == (fixture?["data"] as? [Any])?.count)
        let currencies = Dictionary(uniqueKeysWithValues: territories.map { ($0.id, $0.currency) })
        #expect(currencies["CZE"] == "CZK")
        #expect(currencies["DEU"] == "EUR")
        #expect(currencies["USA"] == "USD")
    }

    @Test func readsSubscriptionsWithAvailabilityAndPlanAvailability() async throws {
        let client = try Self.makeClient(try Self.routedTransport())
        let groups = try await client.subscriptionGroups(appId: "6400000001")
        #expect(groups == [ASCSubscriptionGroup(id: "7000000001", referenceName: "Fruit Premium")])
        let subscriptions = try await client.subscriptions(group: groups[0])
        #expect(subscriptions == [
            SubscriptionInfo(ascId: "6500000001", productId: "fruit.yearly", name: "Fruit Yearly", period: .oneYear, state: .approved,
                             groupId: "7000000001", groupName: "Fruit Premium", availableTerritories: ["USA", "CZE", "DEU"],
                             monthlyPlanAvailable: false, familySharable: false, groupLevel: 1),
            SubscriptionInfo(ascId: "6500000002", productId: "fruit.monthly", name: "Fruit Monthly", period: .oneMonth, state: .readyToSubmit,
                             groupId: "7000000001", groupName: "Fruit Premium", availableTerritories: ["USA", "CZE"],
                             monthlyPlanAvailable: false, familySharable: false, groupLevel: 2),
        ])
    }

    @Test func readsRegularPricesWithCanonicalPlanType() async throws {
        let client = try Self.makeClient(try Self.routedTransport())
        let rows = try await client.regularPrices(subscription: try await yearly(client))
        #expect(rows.count == 5)
        let cze = try #require(rows.first { $0.ascId == "price-cze-1" })
        #expect(cze.planType == .upfront)
        #expect(cze.rawPlanType == nil)
        #expect(cze.customerPrice == Decimal(799))
        #expect(cze.startDate == CalendarDate(iso: "2025-01-15"))
        let scheduled = try #require(rows.first { $0.ascId == "price-usa-2" })
        #expect(scheduled == RegularPriceRow(ascId: "price-usa-2", subscriptionId: "6500000001", territory: "USA", planType: .upfront,
                                             rawPlanType: "UPFRONT", startDate: CalendarDate(iso: "2026-11-01"), preserved: false,
                                             pricePointId: "pp-USA-3499", customerPrice: Decimal(string: "34.99")!))
        #expect(rows.first { $0.ascId == "price-deu-1" }?.preserved == true)
    }

    @Test func missingPlanTypeOnAMonthlyEnabledSubscriptionIsADecodingError() async throws {
        let transport = try Self.routedTransport()
        let client = try Self.makeClient(transport)
        var subscription = try await yearly(client)
        subscription.monthlyPlanAvailable = true
        await #expect(throws: ASCError.decoding("subscriptionPrices price-cze-1: planType missing on a subscription with MONTHLY availability")) {
            _ = try await client.regularPrices(subscription: subscription)
        }
    }

    @Test func readsIntroductoryOffers() async throws {
        let client = try Self.makeClient(try Self.routedTransport())
        let rows = try await client.introductoryOffers(subscription: try await yearly(client)).sorted { $0.ascId < $1.ascId }
        #expect(rows.map(\.ascId) == ["intro-cze-1", "intro-deu-1", "intro-usa-1"])
        #expect(rows[0] == IntroOfferRow(ascId: "intro-cze-1", subscriptionId: "6500000001", territory: "CZE", planType: .upfront,
                                         rawPlanType: nil, mode: .payUpFront, duration: .threeMonths, numberOfPeriods: 1,
                                         startDate: CalendarDate(iso: "2026-01-01"), endDate: CalendarDate(iso: "2026-12-31"),
                                         pricePointId: "pp-CZE-299", customerPrice: Decimal(299)))
        #expect(rows[1].mode == .payAsYouGo)
        #expect(rows[1].customerPrice == Decimal(string: "19.99")!)
        #expect(rows[2].mode == .freeTrial)
        #expect(rows[2].pricePointId == nil)
        #expect(rows[2].customerPrice == nil)
        #expect(rows[2].rawPlanType == "UPFRONT")
    }

    @Test func readsPromotionalOffersWithTheirPrices() async throws {
        let client = try Self.makeClient(try Self.routedTransport())
        let offers = try await client.promotionalOffers(subscription: try await yearly(client))
        #expect(offers == [PromoOffer(
            ascId: "promo-1", subscriptionId: "6500000001", offerCode: "WINBACK_v1", name: "Winback 2026", mode: .payUpFront,
            duration: .threeMonths, numberOfPeriods: 1, planType: .upfront,
            prices: [PromoPrice(ascId: "promo-1-usa", territory: "USA", pricePointId: "pp-USA-1499", customerPrice: Decimal(string: "14.99")!),
                     PromoPrice(ascId: "promo-1-cze", territory: "CZE", pricePointId: "pp-CZE-399", customerPrice: Decimal(399))])])
        #expect(offers[0].prices.map(\.territory) == ["CZE", "USA"])
    }

    @Test func readsPricePointsWithTerritoryAndPlanTypeFilters() async throws {
        let transport = try Self.routedTransport()
        let client = try Self.makeClient(transport)
        _ = try await yearly(client)
        let points = try await client.pricePoints(subscriptionId: "6500000001", territories: ["USA", "CZE"], planType: .upfront)
        #expect(points.count == 4)
        #expect(points.first { $0.id == "pp-USA-2999" } == PricePoint(id: "pp-USA-2999", productAscId: "6500000001", territory: "USA",
                                                                      planType: .upfront, customerPrice: Decimal(string: "29.99")!,
                                                                      proceeds: Decimal(string: "25.49")!))
        let request = try #require(transport.requests.last)
        #expect(request.queryValue("filter[territory]") == "CZE,USA")
        #expect(request.queryValue("filter[planType]") == "UPFRONT")
        #expect(request.queryValue("include") == "territory")
        #expect(request.queryValue("limit") == "8000")
    }

    @Test func pricePointsForNoTerritoriesSendNothing() async throws {
        let transport = FakeTransport()
        let client = try Self.makeClient(transport)
        #expect(try await client.pricePoints(subscriptionId: "6500000001", territories: [], planType: .upfront).isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func readsInAppPurchaseScheduleAndPoints() async throws {
        let client = try Self.makeClient(try Self.routedTransport())
        let iaps = try await client.inAppPurchases(appId: "6400000001")
        #expect(iaps == [IAPInfo(ascId: "6600000001", productId: "fruit.lifetime", name: "Fruit Lifetime", iapType: "NON_CONSUMABLE", state: .approved,
                                 familySharable: false)])
        let schedule = try #require(try await client.iapPriceSchedule(iapId: "6600000001"))
        #expect(schedule == IAPSchedule(iapId: "6600000001", scheduleId: "6600000001", baseTerritory: "USA", manualPrices: [
            IAPManualPrice(ascId: "iap-price-usa", territory: "USA", pricePointId: "iap-USA-4999", startDate: nil, endDate: nil,
                           customerPrice: Decimal(string: "49.99")!),
            IAPManualPrice(ascId: "iap-price-cze", territory: "CZE", pricePointId: "iap-CZE-1290", startDate: CalendarDate(iso: "2026-11-01"),
                           endDate: nil, customerPrice: Decimal(1290)),
        ]))
        let points = try await client.iapPricePoints(iapId: "6600000001", territories: ["USA", "CZE"])
        #expect(points.map(\.id).sorted() == ["iap-CZE-1290", "iap-USA-4999"])
        #expect(points.allSatisfy { $0.planType == nil && $0.productAscId == "6600000001" })
    }

    @Test func missingIAPScheduleIsNil() async throws {
        let transport = try Self.routedTransport()
        transport.on("GET", "/v2/inAppPurchases/6600000001/iapPriceSchedule", .error(status: 404, code: "NOT_FOUND"))
        let client = try Self.makeClient(transport)
        _ = try await client.inAppPurchases(appId: "6400000001")
        #expect(try await client.iapPriceSchedule(iapId: "6600000001") == nil)
    }

    @Test func productsOutsideTheAppAreRefusedUntilListed() async throws {
        let client = try Self.makeClient(try Self.routedTransport())
        await #expect(throws: ASCError.foreignResource("/v1/subscriptions/6500000001/prices")) {
            _ = try await client.regularPrices(subscription: Sample.subscription())
        }
    }

    @Test func countsRequests() async throws {
        let client = try Self.makeClient(try Self.routedTransport())
        _ = try await client.app(id: "6400000001")
        _ = try await client.territories()
        #expect(await client.currentRequestCount() == 2)
    }
}
