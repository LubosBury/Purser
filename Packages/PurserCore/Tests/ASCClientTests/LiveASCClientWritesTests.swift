import Foundation
import Testing
import Domain
@testable import ASCClient
import PurserTestSupport

private actor ScriptedTransport: HTTPTransport {
    private var queue: [(status: Int, body: String)]
    private var requests: [URLRequest] = []

    init(_ responses: [(status: Int, body: String)]) { queue = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json",
                                                      "X-Rate-Limit": "user-hour-lim:3600;user-hour-rem:3500;"])!
        return (Data(next.body.utf8), response)
    }

    func recorded() -> [URLRequest] { requests }
}

private func canonical(_ data: Data?) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data ?? Data())
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

private let products: Set<String> = ["sub-y", "iap-life"]
private let children: Set<String> = ["intro-7", "promo-3", "price-9"]

@Suite("LiveASCClient writes")
struct LiveASCClientWritesTests {
    @Test func createRegularPricePostsGoldenBodyAndMapsRow() async throws {
        let transport = ScriptedTransport([(201, """
        {"data":{"type":"subscriptionPrices","id":"price-777",
                 "attributes":{"startDate":"2026-11-02","preserved":false,"planType":"UPFRONT"}},
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/subscriptionPrices/price-777"}}
        """)])
        let client = LiveASCClient(http: try await WriteTestClients.http(transport: transport, readOnly: false, products: products, children: children))
        let request = NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront,
                                      pricePointId: "pp-sub-y-CZE-12", startDate: CalendarDate(iso: "2026-11-02"),
                                      preserveCurrentPrice: true)
        let row = try await client.createRegularPrice(request)
        #expect(row.ascId == "price-777")
        #expect(row.subscriptionId == "sub-y")
        #expect(row.territory == "CZE")
        #expect(row.planType == .upfront)
        #expect(row.rawPlanType == "UPFRONT")
        #expect(row.startDate == CalendarDate(iso: "2026-11-02"))
        #expect(row.pricePointId == "pp-sub-y-CZE-12")
        let sent = await transport.recorded()
        #expect(sent.count == 1)
        #expect(sent[0].httpMethod == "POST")
        #expect(sent[0].url?.path == "/v1/subscriptionPrices")
        #expect(try canonical(sent[0].httpBody) == canonical(try WriteBodies.createRegularPrice(request).data()))
    }

    @Test func createIntroMapsRowAndKeepsRequestedFields() async throws {
        let transport = ScriptedTransport([(201, """
        {"data":{"type":"subscriptionIntroductoryOffers","id":"intro-8",
                 "attributes":{"duration":"ONE_WEEK","offerMode":"FREE_TRIAL","numberOfPeriods":1,
                               "startDate":"2026-11-05","endDate":null,"targetSubscriptionPlanType":"UPFRONT"}}}
        """)])
        let client = LiveASCClient(http: try await WriteTestClients.http(transport: transport, readOnly: false, products: products, children: children))
        let offer = NewIntroOffer(subscriptionId: "sub-y", territory: "FRA", planType: .upfront, mode: .freeTrial,
                                  duration: .oneWeek, numberOfPeriods: 1, startDate: CalendarDate(iso: "2026-11-05"),
                                  endDate: nil, pricePointId: nil)
        let row = try await client.createIntroductoryOffer(offer)
        #expect(row.ascId == "intro-8")
        #expect(row.territory == "FRA")
        #expect(row.mode == .freeTrial)
        #expect(row.startDate == CalendarDate(iso: "2026-11-05"))
        #expect(row.endDate == nil)
        #expect(row.pricePointId == nil)
        #expect(row.customerPrice == nil)
    }

    @Test func endAndDeleteIntroUsePatchAndDelete() async throws {
        let transport = ScriptedTransport([
            (200, #"{"data":{"type":"subscriptionIntroductoryOffers","id":"intro-7","attributes":{"endDate":"2026-12-01"}}}"#),
            (204, ""),
        ])
        let client = LiveASCClient(http: try await WriteTestClients.http(transport: transport, readOnly: false, products: products, children: children))
        try await client.endIntroductoryOffer(ascId: "intro-7", endDate: CalendarDate(iso: "2026-12-01")!)
        try await client.deleteIntroductoryOffer(ascId: "intro-7")
        let sent = await transport.recorded()
        #expect(sent.map(\.httpMethod) == ["PATCH", "DELETE"])
        #expect(sent.map { $0.url?.path } == ["/v1/subscriptionIntroductoryOffers/intro-7", "/v1/subscriptionIntroductoryOffers/intro-7"])
    }

    @Test func createPromoMapsCreatedPriceIdsFromIncluded() async throws {
        let transport = ScriptedTransport([(201, """
        {"data":{"type":"subscriptionPromotionalOffers","id":"promo-9",
                 "attributes":{"offerCode":"winback_v1","name":"Win back","offerMode":"PAY_AS_YOU_GO",
                               "duration":"ONE_YEAR","numberOfPeriods":1}},
         "included":[
           {"type":"subscriptionPromotionalOfferPrices","id":"pprice-1",
            "relationships":{"territory":{"data":{"type":"territories","id":"CZE"}}}},
           {"type":"subscriptionPromotionalOfferPrices","id":"pprice-2",
            "relationships":{"territory":{"data":{"type":"territories","id":"USA"}}}}]}
        """)])
        let client = LiveASCClient(http: try await WriteTestClients.http(transport: transport, readOnly: false, products: products, children: children))
        let offer = NewPromoOffer(subscriptionId: "sub-y", offerCode: "winback_v1", name: "Win back", mode: .payAsYouGo,
                                  duration: .oneYear, numberOfPeriods: 1, planType: .upfront,
                                  prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-sub-y-USA-2"),
                                           NewPromoPrice(territory: "CZE", pricePointId: "pp-sub-y-CZE-2")])
        let created = try await client.createPromotionalOffer(offer)
        #expect(created.ascId == "promo-9")
        #expect(created.offerCode == "winback_v1")
        #expect(created.prices.map(\.territory) == ["CZE", "USA"])
        #expect(created.prices.map(\.ascId) == ["pprice-1", "pprice-2"])
        #expect(created.prices.map(\.pricePointId) == ["pp-sub-y-CZE-2", "pp-sub-y-USA-2"])
    }

    @Test func replacePromoPricesAndScheduleUseExpectedRoutes() async throws {
        let transport = ScriptedTransport([
            (200, #"{"data":{"type":"subscriptionPromotionalOffers","id":"promo-3"}}"#),
            (201, #"{"data":{"type":"inAppPurchasePriceSchedules","id":"sched-4"}}"#),
            (204, ""), (204, ""),
        ])
        let client = LiveASCClient(http: try await WriteTestClients.http(transport: transport, readOnly: false, products: products, children: children))
        try await client.replacePromotionalOfferPrices(ascId: "promo-3", prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-sub-y-USA-1")])
        try await client.replaceIAPPriceSchedule(NewIAPSchedule(iapId: "iap-life", baseTerritory: "USA", manualPrices: [
            NewIAPManualPrice(territory: "USA", pricePointId: "pp-iap-life-USA-29", startDate: nil, endDate: nil)]))
        try await client.deletePromotionalOffer(ascId: "promo-3")
        try await client.deleteRegularPrice(ascId: "price-9")
        let sent = await transport.recorded()
        #expect(sent.map(\.httpMethod) == ["PATCH", "POST", "DELETE", "DELETE"])
        #expect(sent.map { $0.url?.path } == ["/v1/subscriptionPromotionalOffers/promo-3", "/v1/inAppPurchasePriceSchedules",
                                              "/v1/subscriptionPromotionalOffers/promo-3", "/v1/subscriptionPrices/price-9"])
    }

    @Test func conflictSurfacesAsHTTPErrorWithDetail() async throws {
        let transport = ScriptedTransport([(409, """
        {"errors":[{"id":"e1","status":"409","code":"ENTITY_ERROR","title":"The request entity is not valid.",
                    "detail":"Must delete future price change before creating a new one"}]}
        """)])
        let client = LiveASCClient(http: try await WriteTestClients.http(transport: transport, readOnly: false, products: products, children: children))
        let request = NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront, pricePointId: "pp-sub-y-CZE-12",
                                      startDate: CalendarDate(iso: "2026-11-02"), preserveCurrentPrice: true)
        do {
            _ = try await client.createRegularPrice(request)
            Issue.record("expected a 409")
        } catch let ASCError.http(status, code, _, detail) {
            #expect(status == 409)
            #expect(code == "ENTITY_ERROR")
            #expect(detail?.contains("Must delete future price change") == true)
        }
    }
}
