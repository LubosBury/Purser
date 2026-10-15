import Foundation
import Testing
import ASCClient
import Domain
import PurserTestSupport

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

    // MARK: Read only where Purser never writes

    @Test func productsAreOnlyReadByIdNeverChangedOrDeleted() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001", "6600000001"])
        let patch = body(type: "subscriptions", relationships: "")
        for path in ["/v1/subscriptions/6500000001", "/v2/inAppPurchases/6600000001", "/v1/inAppPurchases/6600000001"] {
            try await guardian.check(method: "GET", path: path, body: nil)
            await #expect(throws: ASCError.foreignResource(path)) { try await guardian.check(method: "DELETE", path: path, body: nil) }
            await #expect(throws: ASCError.foreignResource(path)) { try await guardian.check(method: "PATCH", path: path, body: patch) }
        }
        // Sub-paths of an allowed product are read, never written.
        for path in ["/v1/subscriptions/6500000001/relationships/introductoryOffers", "/v2/inAppPurchases/6600000001/iapPriceSchedule",
                     "/v1/subscriptions/6500000001/prices"] {
            for method in ["POST", "PATCH", "DELETE"] {
                await #expect(throws: ASCError.foreignResource(path), "\(method) \(path)") {
                    try await guardian.check(method: method, path: path, body: patch)
                }
            }
        }
        try await guardian.check(method: "GET", path: "/v1/subscriptions/6500000001/prices", body: nil)
    }

    @Test(arguments: ["subscriptionGroups", "subscriptionAvailabilities", "subscriptionPlanAvailabilities",
                      "inAppPurchasePriceSchedules", "inAppPurchaseAvailabilities"])
    func childrenPurserNeverChangesAreOnlyReadById(collection: String) async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowChildren(["child-1"])
        let path = "/v1/\(collection)/child-1"
        try await guardian.check(method: "GET", path: path, body: nil)
        try await guardian.check(method: "GET", path: path + "/availableTerritories", body: nil)
        let patch = body(type: collection, relationships: "")
        for method in ["PATCH", "DELETE", "POST"] {
            await #expect(throws: ASCError.foreignResource(path), "\(method) \(path)") { try await guardian.check(method: method, path: path, body: patch) }
            await #expect(throws: ASCError.foreignResource(path + "/relationships/x")) {
                try await guardian.check(method: method, path: path + "/relationships/x", body: patch)
            }
        }
    }

    @Test func priceWritesByIdStayAllowed() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowChildren(["price-1", "intro-1", "promo-1"])
        try await guardian.check(method: "DELETE", path: "/v1/subscriptionPrices/price-1", body: nil)
        try await guardian.check(method: "PATCH", path: "/v1/subscriptionIntroductoryOffers/intro-1", body: Data("{}".utf8))
        try await guardian.check(method: "DELETE", path: "/v1/subscriptionIntroductoryOffers/intro-1", body: nil)
        try await guardian.check(method: "PATCH", path: "/v1/subscriptionPromotionalOffers/promo-1", body: Data("{}".utf8))
        try await guardian.check(method: "DELETE", path: "/v1/subscriptionPromotionalOffers/promo-1", body: nil)
        // An IAP price schedule is replaced by a POST without an id.
        await guardian.allowProducts(["6600000001"])
        let schedule = body(type: "inAppPurchasePriceSchedules",
                            relationships: #""inAppPurchase":{"data":{"type":"inAppPurchases","id":"6600000001"}}"#)
        try await guardian.check(method: "POST", path: "/v1/inAppPurchasePriceSchedules", body: schedule)
    }

    // MARK: Localized metadata (read only)

    @Test func versionsAreReadOnlyUnderAllowedOwners() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001", "6600000001"])
        await guardian.allowChildren(["7000000001"])
        try await guardian.check(method: "GET", path: "/v1/subscriptions/6500000001/versions", body: nil)
        try await guardian.check(method: "GET", path: "/v2/inAppPurchases/6600000001/versions", body: nil)
        try await guardian.check(method: "GET", path: "/v1/subscriptionGroups/7000000001/versions", body: nil)
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/subscriptions/6500000999/versions", body: nil) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v2/inAppPurchases/6600000999/versions", body: nil) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/subscriptionGroups/7000000999/versions", body: nil) }

        for collection in ["subscriptionVersions", "inAppPurchaseVersions", "subscriptionGroupVersions"] {
            let id = "ver-\(collection)"
            let texts = "/v1/\(collection)/\(id)/localizations"
            await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: texts, body: nil) }
            await guardian.allowChildren([id])
            try await guardian.check(method: "GET", path: texts, body: nil)
            try await guardian.check(method: "GET", path: "/v1/\(collection)/\(id)", body: nil)
            // A version POST may name only an allowed owner; 6500000999 is foreign.
            let create = body(type: collection, relationships: #""subscription":{"data":{"type":"subscriptions","id":"6500000999"}}"#)
            await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/\(collection)", body: create) }
            await #expect(throws: ASCError.self) { try await guardian.check(method: "PATCH", path: "/v1/\(collection)/\(id)", body: create) }
            await #expect(throws: ASCError.self) { try await guardian.check(method: "DELETE", path: "/v1/\(collection)/\(id)", body: nil) }
        }
    }

    @Test func localizationResourcesOpenOnlyForKnownVersionsAndIds() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001"])
        await guardian.allowChildren(["ver-1", "loc-1"])
        let kinds = [("subscriptionLocalizations", "subscriptionVersions"), ("inAppPurchaseLocalizations", "inAppPurchaseVersions"),
                     ("subscriptionGroupLocalizations", "subscriptionGroupVersions")]
        for (collection, versionType) in kinds {
            let create = body(type: collection, relationships: #""version":{"data":{"type":"\#(versionType)","id":"ver-1"}}"#)
            let unknownVersion = body(type: collection, relationships: #""version":{"data":{"type":"\#(versionType)","id":"ver-9"}}"#)
            try await guardian.check(method: "GET", path: "/v2/\(collection)/loc-1", body: nil)
            try await guardian.check(method: "POST", path: "/v2/\(collection)", body: create)
            await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v2/\(collection)", body: unknownVersion) }
            await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v2/\(collection)/loc-9", body: nil) }
            await #expect(throws: ASCError.self) { try await guardian.check(method: "PATCH", path: "/v2/\(collection)/loc-9", body: create) }
            await #expect(throws: ASCError.self) { try await guardian.check(method: "DELETE", path: "/v2/\(collection)/loc-1", body: nil) }
        }
    }

    // MARK: Cloning: review screenshots and availability of in-app purchases

    @Test func aScreenshotReservationMustNameAnAllowedProduct() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001", "6600000001"])
        func reservation(_ relationship: String, _ type: String, _ id: String) -> Data {
            body(type: "x", relationships: #""\#(relationship)":{"data":{"type":"\#(type)","id":"\#(id)"}}"#)
        }
        try await guardian.check(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots",
                                 body: reservation("subscription", "subscriptions", "6500000001"))
        try await guardian.check(method: "POST", path: "/v1/inAppPurchaseAppStoreReviewScreenshots",
                                 body: reservation("inAppPurchaseV2", "inAppPurchases", "6600000001"))
        await #expect(throws: ASCError.self) {
            try await guardian.check(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots",
                                     body: reservation("subscription", "subscriptions", "6500000999"))
        }
        await #expect(throws: ASCError.self) {
            try await guardian.check(method: "POST", path: "/v1/inAppPurchaseAppStoreReviewScreenshots", body: self.body(type: "x", relationships: ""))
        }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots", body: nil) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "GET", path: "/v1/subscriptionAppStoreReviewScreenshots", body: nil) }
    }

    @Test func aScreenshotReservationUsesTheRelationshipOfItsOwnCollection() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001", "6600000001"])
        func reservation(_ relationship: String, _ type: String, _ id: String) -> Data {
            body(type: "x", relationships: #""\#(relationship)":{"data":{"type":"\#(type)","id":"\#(id)"}}"#)
        }
        let subscription = reservation("subscription", "subscriptions", "6500000001")
        let purchase = reservation("inAppPurchaseV2", "inAppPurchases", "6600000001")
        // Each collection takes only its own product kind through its own relationship, on the exact v1 collection path.
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots", body: purchase) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/inAppPurchaseAppStoreReviewScreenshots", body: subscription) }
        await #expect(throws: ASCError.self) {
            try await guardian.check(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots",
                                     body: reservation("group", "subscriptions", "6500000001"))
        }
        await #expect(throws: ASCError.self) {
            try await guardian.check(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots",
                                     body: reservation("subscription", "inAppPurchases", "6500000001"))
        }
        // A second relationship that names a foreign product is refused even next to an allowed one.
        let smuggled = body(type: "x", relationships: #""subscription":{"data":{"type":"subscriptions","id":"6500000001"}},"other":{"data":{"type":"subscriptions","id":"6500000999"}}"#)
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots", body: smuggled) }
        await #expect(throws: ASCError.self) { try await guardian.check(method: "POST", path: "/v2/subscriptionAppStoreReviewScreenshots", body: subscription) }
        // A known id does not open a sub-resource of a screenshot: the refusal comes from the screenshot rule.
        await guardian.allowChildren(["6500000001"])
        await #expect(throws: ASCError.self) {
            try await guardian.check(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots/6500000001/x", body: subscription)
        }
    }

    private static func commit(_ collection: String, _ id: String) -> Data {
        Data(#"{"data":{"type":"\#(collection)","id":"\#(id)","attributes":{"uploaded":true,"sourceFileChecksum":"00"}}}"#.utf8)
    }

    @Test func aScreenshotLearnedByAReadIsReadNeverChanged() async throws {
        let guardian = AppGuard(appId: "6400000001")
        for method in ["PATCH", "DELETE", "GET"] {
            await #expect(throws: ASCError.self) {
                try await guardian.check(method: method, path: "/v1/subscriptionAppStoreReviewScreenshots/shot-1", body: Data("{}".utf8))
            }
        }
        // Learned by a read (GET …/appStoreReviewScreenshot of a source product): a screenshot this client did not reserve.
        await guardian.allowChildren(["shot-1", "shot-2"])
        try await guardian.check(method: "GET", path: "/v1/subscriptionAppStoreReviewScreenshots/shot-1", body: nil)
        let changes: [(String, String, Data?)] = [
            ("PATCH", "/v1/subscriptionAppStoreReviewScreenshots/shot-1", Self.commit("subscriptionAppStoreReviewScreenshots", "shot-1")),
            ("DELETE", "/v1/subscriptionAppStoreReviewScreenshots/shot-1", nil),
            ("PATCH", "/v1/inAppPurchaseAppStoreReviewScreenshots/shot-2", Self.commit("inAppPurchaseAppStoreReviewScreenshots", "shot-2")),
            ("DELETE", "/v1/inAppPurchaseAppStoreReviewScreenshots/shot-2", nil),
        ]
        for (method, path, body) in changes {
            await #expect(throws: ASCError.foreignResource(path), "\(method) \(path)") {
                try await guardian.check(method: method, path: path, body: body)
            }
        }
    }

    @Test func aReservationIsForgottenOnceItsCommitOrDeleteSucceeded() async throws {
        let transport = FakeTransport()
        let collection = "subscriptionAppStoreReviewScreenshots"
        transport.on("POST", "/v1/\(collection)", .json(#"{"data":{"type":"\#(collection)","id":"shot-1"}}"#, status: 201),
                     .json(#"{"data":{"type":"\#(collection)","id":"shot-2"}}"#, status: 201))
        transport.on("PATCH", "/v1/\(collection)/shot-1", .error(status: 409, code: "ENTITY_ERROR"),
                     .json(#"{"data":{"type":"\#(collection)","id":"shot-1"}}"#))
        transport.on("DELETE", "/v1/\(collection)/shot-2", FakeResponse(status: 204, body: Data()))
        let guardian = AppGuard(appId: Sample.appId)
        let client = try await WriteTestClients.http(transport: transport, readOnly: false, products: ["6500000001"], appGuard: guardian,
                                                     now: { Sample.fixedNow })
        let reservation = body(type: collection, relationships: #""subscription":{"data":{"type":"subscriptions","id":"6500000001"}}"#)
        _ = try await client.send(method: "POST", path: "/v1/\(collection)", body: reservation)
        _ = try await client.send(method: "POST", path: "/v1/\(collection)", body: reservation)

        // A refused commit keeps the reservation; a 2xx commit ends it: the screenshot is finished and no longer this client's.
        let first = "/v1/\(collection)/shot-1"
        await #expect(throws: ASCError.self) { _ = try await client.send(method: "PATCH", path: first, body: Self.commit(collection, "shot-1")) }
        try await guardian.check(method: "DELETE", path: first, body: nil)
        _ = try await client.send(method: "PATCH", path: first, body: Self.commit(collection, "shot-1"))
        await #expect(throws: ASCError.foreignResource(first)) { try await guardian.check(method: "PATCH", path: first, body: Self.commit(collection, "shot-1")) }
        await #expect(throws: ASCError.foreignResource(first)) { try await guardian.check(method: "DELETE", path: first, body: nil) }
        try await guardian.check(method: "GET", path: first, body: nil)

        // A 2xx DELETE (204, no body) ends it too.
        let second = "/v1/\(collection)/shot-2"
        try await client.delete(path: second)
        await #expect(throws: ASCError.foreignResource(second)) { try await guardian.check(method: "DELETE", path: second, body: nil) }
        await #expect(throws: ASCError.foreignResource(second)) {
            try await guardian.check(method: "PATCH", path: second, body: Self.commit(collection, "shot-2"))
        }
    }

    @Test func onlyAReservationThisClientMadeIsCommittedOrDeleted() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/v1/subscriptionAppStoreReviewScreenshots", .json(
            #"{"data":{"type":"subscriptionAppStoreReviewScreenshots","id":"shot-9"},"included":[{"type":"subscriptionAppStoreReviewScreenshots","id":"shot-7"}]}"#,
            status: 201))
        transport.on("POST", "/v1/subscriptionAvailabilities",
                     .json(#"{"data":{"type":"subscriptionAppStoreReviewScreenshots","id":"shot-8"}}"#, status: 201))
        let guardian = AppGuard(appId: Sample.appId)
        let client = try await WriteTestClients.http(transport: transport, readOnly: false, products: ["6500000001"], appGuard: guardian,
                                                     now: { Sample.fixedNow })
        let path = "/v1/subscriptionAppStoreReviewScreenshots/shot-9"
        await #expect(throws: ASCError.self) { try await guardian.check(method: "DELETE", path: path, body: nil) }
        // The primary resource of the answer to an admitted reservation; never an included one or the answer to another POST.
        let product = #""subscription":{"data":{"type":"subscriptions","id":"6500000001"}}"#
        _ = try await client.send(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots",
                                  body: body(type: "subscriptionAppStoreReviewScreenshots", relationships: product))
        _ = try await client.send(method: "POST", path: "/v1/subscriptionAvailabilities",
                                  body: body(type: "subscriptionAvailabilities", relationships: product))
        try await guardian.check(method: "PATCH", path: path, body: Self.commit("subscriptionAppStoreReviewScreenshots", "shot-9"))
        try await guardian.check(method: "DELETE", path: path, body: nil)
        try await guardian.check(method: "GET", path: path, body: nil)
        for id in ["shot-7", "shot-8"] {
            await #expect(throws: ASCError.self, "\(id)") {
                try await guardian.check(method: "DELETE", path: "/v1/subscriptionAppStoreReviewScreenshots/\(id)", body: nil)
            }
        }
        // The commit names the same screenshot; no sub-resource, no other method, v1 only.
        let wrong: [(String, String, Data?)] = [
            ("PATCH", path, Self.commit("subscriptionAppStoreReviewScreenshots", "shot-1")),
            ("PATCH", path, Self.commit("inAppPurchaseAppStoreReviewScreenshots", "shot-9")),
            ("PATCH", path, nil),
            ("DELETE", path + "/x", nil),
            ("POST", path, Self.commit("subscriptionAppStoreReviewScreenshots", "shot-9")),
            ("PUT", path, Self.commit("subscriptionAppStoreReviewScreenshots", "shot-9")),
            ("DELETE", "/v2/subscriptionAppStoreReviewScreenshots/shot-9", nil),
        ]
        for (method, path, body) in wrong {
            await #expect(throws: ASCError.self, "\(method) \(path)") { try await guardian.check(method: method, path: path, body: body) }
        }
    }

    @Test func theSourceScreenshotIsNeverChangedWhileTheClonesOwnReservationIs() async throws {
        let fake = FakeASC(model: FakeSeed.cloneSource(), now: { Sample.fixedNow })
        let guardian = AppGuard(appId: FakeSeed.appId)
        let write = try await WriteTestClients.http(transport: fake, readOnly: false, products: ["sub-spike-a", "sub-y"], appGuard: guardian,
                                                    now: { Sample.fixedNow })
        let read = LiveASCClient(http: try await WriteTestClients.http(transport: fake, readOnly: true, products: [], appGuard: guardian,
                                                                       now: { Sample.fixedNow }))
        let source = try #require(try await read.reviewScreenshot(of: .subscription("sub-spike-a")))
        let sourcePath = "/v1/subscriptionAppStoreReviewScreenshots/\(source.ascId)"
        await #expect(throws: ASCError.foreignResource(sourcePath)) { try await write.delete(path: sourcePath) }
        await #expect(throws: ASCError.foreignResource(sourcePath)) {
            _ = try await write.send(method: "PATCH", path: sourcePath, body: Self.commit("subscriptionAppStoreReviewScreenshots", source.ascId))
        }
        #expect(await fake.writeRequests().isEmpty)

        // sub-y stands in for a clone: the reservation this client made for it may be committed or deleted.
        let reservation = Data(#"{"data":{"type":"subscriptionAppStoreReviewScreenshots","attributes":{"fileName":"a.png","fileSize":70},"relationships":{"subscription":{"data":{"type":"subscriptions","id":"sub-y"}}}}}"#.utf8)
        let clone = try #require(try await write.send(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots", body: reservation)?
            .data.first?.id)
        let clonePath = "/v1/subscriptionAppStoreReviewScreenshots/\(clone)"
        try await guardian.check(method: "PATCH", path: clonePath, body: Self.commit("subscriptionAppStoreReviewScreenshots", clone))
        try await write.delete(path: clonePath)
        let model = await fake.model
        #expect(!model.screenshots.contains { $0.id == clone })
        #expect(model.screenshots.first { $0.id == source.ascId }?.state == "COMPLETE")
    }

    @Test func productAssetsAreReadOnlyUnderAllowedProducts() async throws {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001", "6600000001"])
        try await guardian.check(method: "GET", path: "/v1/subscriptions/6500000001/appStoreReviewScreenshot", body: nil)
        try await guardian.check(method: "GET", path: "/v2/inAppPurchases/6600000001/appStoreReviewScreenshot", body: nil)
        try await guardian.check(method: "GET", path: "/v2/inAppPurchases/6600000001/inAppPurchaseAvailability", body: nil)
        await #expect(throws: ASCError.self) {
            try await guardian.check(method: "GET", path: "/v2/inAppPurchases/6600000999/inAppPurchaseAvailability", body: nil)
        }
        await #expect(throws: ASCError.self) {
            try await guardian.check(method: "GET", path: "/v1/inAppPurchaseAvailabilities/iav-1/availableTerritories", body: nil)
        }
        await guardian.allowChildren(["iav-1"])
        try await guardian.check(method: "GET", path: "/v1/inAppPurchaseAvailabilities/iav-1/availableTerritories", body: nil)
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
