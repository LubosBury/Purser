import Foundation
import Testing
import ASCClient
import Domain
import PurserTestSupport

@Suite struct EqualizationsTests {
    @Test func readsTheEquivalentPricePointOfEveryOtherTerritory() async throws {
        let pointId = AppGuardTests.pricePointId(subscription: "6500000001")
        let transport = QueueHTTPTransport([(200, """
        {"data":[
          {"type":"subscriptionPricePoints","id":"pp-cze","attributes":{"customerPrice":"799.0","proceeds":"560.0"},
           "relationships":{"territory":{"data":{"type":"territories","id":"CZE"}}}},
          {"type":"subscriptionPricePoints","id":"pp-deu","attributes":{"customerPrice":"29.99","proceeds":"21.0"},
           "relationships":{"territory":{"data":{"type":"territories","id":"DEU"}}}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/subscriptionPricePoints/x/equalizations"}}
        """)])
        let http = try await WriteTestClients.http(transport: transport, readOnly: true, products: ["6500000001"])
        let points = try await LiveASCClient(http: http).equalizations(subscriptionId: "6500000001", pricePointId: pointId, planType: .upfront)
        #expect(points.map(\.territory) == ["CZE", "DEU"])
        #expect(points.map(\.customerPrice) == [Decimal(string: "799.0")!, Decimal(string: "29.99")!])
        #expect(points.allSatisfy { $0.productAscId == "6500000001" && $0.planType == .upfront })
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/subscriptionPricePoints/\(pointId)/equalizations")
        #expect(request.url?.query?.contains("include=territory") == true)
    }

    @Test func aPricePointOfAnotherSubscriptionIsRefusedBeforeSending() async throws {
        let transport = QueueHTTPTransport([])
        let http = try await WriteTestClients.http(transport: transport, readOnly: true, products: ["6500000001"])
        let foreign = AppGuardTests.pricePointId(subscription: "6500000999")
        await #expect(throws: ASCError.self) {
            _ = try await LiveASCClient(http: http).equalizations(subscriptionId: "6500000999", pricePointId: foreign, planType: .upfront)
        }
        #expect(await transport.requests.isEmpty)
    }
}
