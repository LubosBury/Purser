import Foundation
import Testing
import ASCClient
import Domain
import PurserTestSupport

@Suite struct ProductAssetsReadingTests {
    private static let territories = #"{"data":[{"type":"territories","id":"USA","attributes":{"currency":"USD"}},{"type":"territories","id":"CZE","attributes":{"currency":"CZK"}}],"links":{"self":"https://api.appstoreconnect.apple.com/v1/x"}}"#

    private func client(_ transport: FakeTransport) async throws -> LiveASCClient {
        LiveASCClient(http: try await WriteTestClients.http(transport: transport, readOnly: true, products: ["6500000001", "6600000001"],
                                                            appGuard: AppGuard(appId: Sample.appId), now: { Sample.fixedNow }))
    }

    @Test func subscriptionAvailabilityCarriesTheNewTerritoriesFlag() async throws {
        let t = FakeTransport()
        t.on("GET", "/v1/subscriptions/6500000001/subscriptionAvailability",
             .json(#"{"data":{"type":"subscriptionAvailabilities","id":"av-1","attributes":{"availableInNewTerritories":true}}}"#))
        t.on("GET", "/v1/subscriptionAvailabilities/av-1/availableTerritories", .json(Self.territories))
        let availability = try await client(t).subscriptionAvailability(subscriptionId: "6500000001")
        #expect(availability == ProductAvailability(territories: ["USA", "CZE"], availableInNewTerritories: true))
        #expect(t.requests.last?.queryValue("limit") == "200")
    }

    @Test func iapAvailabilityIsReadAndAMissingOneIsNil() async throws {
        let t = FakeTransport()
        t.on("GET", "/v2/inAppPurchases/6600000001/inAppPurchaseAvailability",
             .json(#"{"data":{"type":"inAppPurchaseAvailabilities","id":"iav-1","attributes":{"availableInNewTerritories":false}}}"#))
        t.on("GET", "/v1/inAppPurchaseAvailabilities/iav-1/availableTerritories", .json(Self.territories))
        let reader = try await client(t)
        #expect(try await reader.iapAvailability(iapId: "6600000001")
                == ProductAvailability(territories: ["USA", "CZE"], availableInNewTerritories: false))
        t.on("GET", "/v2/inAppPurchases/6600000001/inAppPurchaseAvailability", .error(status: 404, code: "NOT_FOUND"))
        #expect(try await reader.iapAvailability(iapId: "6600000001") == nil)
        t.on("GET", "/v1/subscriptions/6500000001/subscriptionAvailability", .error(status: 404, code: "NOT_FOUND"))
        #expect(try await reader.subscriptionAvailability(subscriptionId: "6500000001") == nil)
    }

    @Test func reviewScreenshotMapsTheImageAssetAndTheState() async throws {
        let t = FakeTransport()
        t.on("GET", "/v1/subscriptions/6500000001/appStoreReviewScreenshot", .json("""
        {"data":{"type":"subscriptionAppStoreReviewScreenshots","id":"shot-1","attributes":{"fileName":"review.png","fileSize":4096,
          "sourceFileChecksum":"abc","imageAsset":{"templateUrl":"https://is1-ssl.mzstatic.com/image/thumb/x/{w}x{h}bb.{f}","width":1242,"height":2688},
          "assetDeliveryState":{"state":"COMPLETE","errors":[],"warnings":[]}}}}
        """))
        t.on("GET", "/v2/inAppPurchases/6600000001/appStoreReviewScreenshot", .json(#"{"data":null}"#))
        let reader = try await client(t)
        let shot = try #require(try await reader.reviewScreenshot(of: .subscription("6500000001")))
        #expect(shot == ReviewScreenshot(ascId: "shot-1", fileName: "review.png", fileSize: 4096,
                                         templateURL: "https://is1-ssl.mzstatic.com/image/thumb/x/{w}x{h}bb.{f}",
                                         width: 1242, height: 2688, deliveryState: "COMPLETE"))
        #expect(shot.isDownloadable)
        #expect(try await reader.reviewScreenshot(of: .iap("6600000001")) == nil)
        let before = t.requests.count
        #expect(try await reader.reviewScreenshot(of: .group("7000000001")) == nil)
        #expect(t.requests.count == before)
        t.on("GET", "/v1/subscriptions/6500000001/appStoreReviewScreenshot", .error(status: 404, code: "NOT_FOUND"))
        #expect(try await reader.reviewScreenshot(of: .subscription("6500000001")) == nil)
    }

    @Test func productsOutsideTheAppAreRefused() async throws {
        let reader = try await client(FakeTransport())
        await #expect(throws: ASCError.self) { _ = try await reader.reviewScreenshot(of: .subscription("6500000999")) }
        await #expect(throws: ASCError.self) { _ = try await reader.iapAvailability(iapId: "6600000999") }
    }
}
