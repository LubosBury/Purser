import Foundation
import Testing
import ASCClient

@Suite struct AppGuardTests {
    @Test func allowsOnlyTheWorkspaceApp() async throws {
        let guardian = AppGuard(appId: "6400000001")
        try await guardian.check(method: "GET", path: "/v1/apps/6400000001", body: nil)
        try await guardian.check(method: "GET", path: "/v1/apps/6400000001/subscriptionGroups", body: nil)
        try await guardian.check(method: "GET", path: "/v1/territories", body: nil)
        await #expect(throws: ASCError.foreignResource("/v1/apps/6400000002/subscriptionGroups")) {
            try await guardian.check(method: "GET", path: "/v1/apps/6400000002/subscriptionGroups", body: nil)
        }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/apps", body: nil) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/territories", body: Data("{}".utf8)) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/users", body: nil) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/apps/6400000001/../6400000002", body: nil) }
    }

    @Test func productsAndChildrenMustBeLearnedFirst() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/subscriptions/6500000001/prices", body: nil) }
        await guardian.allowProducts(["6500000001", "6600000001"])
        try await guardian.check(method: "GET", path: "/v1/subscriptions/6500000001/prices", body: nil)
        try await guardian.check(method: "GET", path: "/v2/inAppPurchases/6600000001/pricePoints", body: nil)
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/subscriptions/6500000999/prices", body: nil) }

        await #expect(throws: ASCError.self) { try await guardian.check(method: "DELETE", path: "/v1/subscriptionPrices/price-1", body: nil) }
        await guardian.allowChildren(["price-1", "7000000001"])
        try await guardian.check(method: "DELETE", path: "/v1/subscriptionPrices/price-1", body: nil)
        try await guardian.check(method: "GET", path: "/v1/subscriptionGroups/7000000001/subscriptions", body: nil)
    }

    @Test func createBodiesMustReferenceAllowedProductsOnly() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001"])
        let own = Data("""
        {"data":{"type":"subscriptionPrices","attributes":{"preserveCurrentPrice":true},
          "relationships":{"subscription":{"data":{"type":"subscriptions","id":"6500000001"}},
                           "subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"pp-USA-3499"}}}}}
        """.utf8)
        try await guardian.check(method: "POST", path: "/v1/subscriptionPrices", body: own)
        let foreign = Data(String(decoding: own, as: UTF8.self).replacingOccurrences(of: "6500000001", with: "6500000999").utf8)
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/subscriptionPrices", body: foreign) }
        let noProduct = Data(#"{"data":{"type":"subscriptionPrices","relationships":{}}}"#.utf8)
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/subscriptionPrices", body: noProduct) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/subscriptionPrices", body: nil) }
    }

    @Test func createBodiesWithToManyRelationshipsMustReferenceAllowedProductsOnly() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001", "6500000002"])
        func body(toMany ids: [String]) -> Data {
            let targets = ids.map { #"{"type":"subscriptions","id":"\#($0)"}"# }.joined(separator: ",")
            return Data("""
            {"data":{"type":"subscriptionPrices",
              "relationships":{"subscription":{"data":{"type":"subscriptions","id":"6500000001"}},
                               "others":{"data":[\(targets)]}}}}
            """.utf8)
        }
        try await guardian.check(method: "POST", path: "/v1/subscriptionPrices", body: body(toMany: ["6500000002"]))
        await #expect(throws: ASCError.self) {
            try await guardian.check(method: "POST", path: "/v1/subscriptionPrices", body: body(toMany: ["6500000002", "6500000999"]))
        }
    }

    // MARK: Product creation (v1 scope change: groups, subscriptions and non-consumables are created by Purser)

    private func body(type: String, relationships: String) -> Data {
        Data(#"{"data":{"type":"\#(type)","attributes":{},"relationships":{\#(relationships)}}}"#.utf8)
    }

    @Test func groupsAndInAppPurchasesAreCreatedOnlyUnderTheWorkspaceApp() async throws {
        let guardian = AppGuard(appId: "6400000001")
        let own = #""app":{"data":{"type":"apps","id":"6400000001"}}"#
        let foreign = #""app":{"data":{"type":"apps","id":"6400000002"}}"#
        try await guardian.check(method: "POST", path: "/v1/subscriptionGroups", body: body(type: "subscriptionGroups", relationships: own))
        try await guardian.check(method: "POST", path: "/v2/inAppPurchases", body: body(type: "inAppPurchases", relationships: own))
        for path in ["/v1/subscriptionGroups", "/v2/inAppPurchases"] {
            await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: path, body: self.body(type: "x", relationships: foreign)) }
            await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: path, body: self.body(type: "x", relationships: "")) }
            await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: path, body: nil) }
            await #expect(throws: ASCError.self) { try await guardian.check(method: "DELETE", path: path, body: nil) }
        }
    }

    @Test func subscriptionsAreCreatedOnlyInAKnownGroup() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowChildren(["7000000001"])
        func group(_ id: String) -> Data { body(type: "subscriptions", relationships: #""group":{"data":{"type":"subscriptionGroups","id":"\#(id)"}}"#) }
        try await guardian.check(method: "POST", path: "/v1/subscriptions", body: group("7000000001"))
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/subscriptions", body: group("7000000999")) }
        let wrongType = body(type: "subscriptions", relationships: #""group":{"data":{"type":"apps","id":"7000000001"}}"#)
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/subscriptions", body: wrongType) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/subscriptions", body: nil) }
    }

    @Test func availabilityIsCreatedOnlyForAllowedProducts() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001", "6600000001"])
        func availability(_ relationship: String, _ type: String, _ id: String) -> Data {
            body(type: "x", relationships: #""\#(relationship)":{"data":{"type":"\#(type)","id":"\#(id)"}},"availableTerritories":{"data":[{"type":"territories","id":"USA"}]}"#)
        }
        try await guardian.check(method: "POST", path: "/v1/subscriptionAvailabilities", body: availability("subscription", "subscriptions", "6500000001"))
        try await guardian.check(method: "POST", path: "/v1/inAppPurchaseAvailabilities", body: availability("inAppPurchase", "inAppPurchases", "6600000001"))
        await #expect(throws: ASCError.self) {
            try await guardian.check(method: "POST", path: "/v1/inAppPurchaseAvailabilities", body: availability("inAppPurchase", "inAppPurchases", "6600000999"))
        }
    }

    static func pricePointId(subscription: String, territory: String = "USA", tier: String = "10123") -> String {
        Data(#"{"s":"\#(subscription)","t":"\#(territory)","p":"\#(tier)"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    @Test func equalizationsAreReadOnlyForPricePointsOfAllowedSubscriptions() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001"])
        let own = Self.pricePointId(subscription: "6500000001")
        let foreign = Self.pricePointId(subscription: "6500000999")
        try await guardian.check(method: "GET", path: "/v1/subscriptionPricePoints/\(own)/equalizations", body: nil)
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/subscriptionPricePoints/\(foreign)/equalizations", body: nil) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/subscriptionPricePoints/not-a-point/equalizations", body: nil) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/subscriptionPricePoints/\(own)", body: nil) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "DELETE", path: "/v1/subscriptionPricePoints/\(own)/equalizations", body: nil) }
    }
}
