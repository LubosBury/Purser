import Foundation
import Testing
import ASCClient
import Domain
import PurserTestSupport

/// FakeASC for cloning: product creation, availability, the review screenshot cycle and Apple's upload and image hosts.
@Suite("FakeASC cloning semantics")
struct FakeASCCloneTests {
    private struct Clients {
        let fake: FakeASC
        let write: ASCHTTPClient
        let read: LiveASCClient
        let guardian: AppGuard
    }

    private func clients(_ model: FakeModel = FakeSeed.fruitJarWithSpikeGroup()) async throws -> Clients {
        let fake = FakeASC(model: model, now: { Sample.fixedNow })
        let guardian = AppGuard(appId: FakeSeed.appId)
        let write = try await WriteTestClients.http(transport: fake, readOnly: false, products: ["sub-spike-a", "iap-spike"],
                                                    children: ["grp-spike"], appGuard: guardian, now: { Sample.fixedNow })
        let read = LiveASCClient(http: try await WriteTestClients.http(transport: fake, readOnly: true, products: [], appGuard: guardian,
                                                                       now: { Sample.fixedNow }))
        return Clients(fake: fake, write: write, read: read, guardian: guardian)
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func subscription(_ productId: String, level: Int? = nil) -> [String: Any] {
        var attributes: [String: Any] = ["name": productId, "productId": productId, "subscriptionPeriod": "ONE_YEAR",
                                         "familySharable": true, "reviewNote": "Synthetic note"]
        if let level { attributes["groupLevel"] = level }
        return ["data": ["type": "subscriptions", "attributes": attributes,
                         "relationships": ["group": ["data": ["type": "subscriptionGroups", "id": "grp-spike"]]]]]
    }

    private func reservation() -> [String: Any] {
        ["data": ["type": "subscriptionAppStoreReviewScreenshots",
                  "attributes": ["fileName": "a.png", "fileSize": FakeASC.samplePNG.count],
                  "relationships": ["subscription": ["data": ["type": "subscriptions", "id": "sub-spike-a"]]]]]
    }

    @Test func aCreatedSubscriptionHasVersionOneWithoutTextsAndItsPricePoints() async throws {
        let c = try await clients()
        let document = try #require(try await c.write.send(method: "POST", path: "/v1/subscriptions", body: try json(subscription("SpikeYearlyA_T1"))))
        let id = try #require(document.data.first?.id)
        let model = await c.fake.model
        let created = try #require(model.subscriptions.first { $0.id == id })
        #expect(created.state == .missingMetadata)
        #expect(created.familySharable && created.reviewNote == "Synthetic note")
        #expect(created.groupLevel == 2)          // below sub-spike-a, the only level of grp-spike so far
        #expect(created.availableTerritories.isEmpty)
        #expect(model.pricePoints.filter { $0.productId == id }.count == 40 * model.territories.count)
        let version = try #require(model.versions.first { $0.owner == .subscription(id) })
        #expect(version.number == 1 && version.state == .prepareForSubmission)
        #expect(!model.localizations.contains { $0.versionId == version.id })
        await #expect(throws: ASCError.self) {
            _ = try await c.write.send(method: "POST", path: "/v1/subscriptions", body: try self.json(self.subscription("SpikeYearlyA_T1")))
        }
        let leveled = try #require(try await c.write.send(method: "POST", path: "/v1/subscriptions",
                                                          body: try json(subscription("SpikeYearlyA_T2", level: 1)))?.data.first?.id)
        #expect(await c.fake.model.subscriptions.first { $0.id == leveled }?.groupLevel == 1)
    }

    @Test func aCreatedGroupHasVersionOne() async throws {
        let c = try await clients()
        let group = try #require(try await c.write.send(method: "POST", path: "/v1/subscriptionGroups", body: try json([
            "data": ["type": "subscriptionGroups", "attributes": ["referenceName": "Purser Spike B"],
                     "relationships": ["app": ["data": ["type": "apps", "id": FakeSeed.appId]]]]]))?.data.first?.id)
        let model = await c.fake.model
        #expect(model.groups.contains(FakeGroup(id: group, name: "Purser Spike B")))
        #expect(model.versions.filter { $0.owner == .group(group) }.map(\.number) == [1])
    }

    @Test func availabilityIsThereOnlyAfterItWasCreated() async throws {
        let c = try await clients()
        let sub = try #require(try await c.write.send(method: "POST", path: "/v1/subscriptions",
                                                      body: try json(subscription("SpikeYearlyA_T1")))?.data.first?.id)
        await c.guardian.allowProducts([sub])
        #expect(try await c.read.subscriptionAvailability(subscriptionId: sub) == nil)
        _ = try await c.write.send(method: "POST", path: "/v1/subscriptionAvailabilities", body: try json([
            "data": ["type": "subscriptionAvailabilities", "attributes": ["availableInNewTerritories": true],
                     "relationships": ["subscription": ["data": ["type": "subscriptions", "id": sub]],
                                       "availableTerritories": ["data": [["type": "territories", "id": "USA"],
                                                                         ["type": "territories", "id": "CZE"]]]]]]))
        #expect(try await c.read.subscriptionAvailability(subscriptionId: sub)
                == ProductAvailability(territories: ["USA", "CZE"], availableInNewTerritories: true))

        let iap = try #require(try await c.write.send(method: "POST", path: "/v2/inAppPurchases", body: try json([
            "data": ["type": "inAppPurchases",
                     "attributes": ["name": "Lifetime_T1", "productId": "Lifetime_T1", "inAppPurchaseType": "NON_CONSUMABLE"],
                     "relationships": ["app": ["data": ["type": "apps", "id": FakeSeed.appId]]]]]))?.data.first?.id)
        await c.guardian.allowProducts([iap])
        #expect(await c.fake.model.pricePoints.filter { $0.productId == iap }.count == 60 * 6)
        #expect(try await c.read.iapAvailability(iapId: iap) == nil)
        _ = try await c.write.send(method: "POST", path: "/v1/inAppPurchaseAvailabilities", body: try json([
            "data": ["type": "inAppPurchaseAvailabilities", "attributes": ["availableInNewTerritories": false],
                     "relationships": ["inAppPurchase": ["data": ["type": "inAppPurchases", "id": iap]],
                                       "availableTerritories": ["data": [["type": "territories", "id": "USA"]]]]]]))
        #expect(try await c.read.iapAvailability(iapId: iap) == ProductAvailability(territories: ["USA"], availableInNewTerritories: false))
    }

    @Test func aScreenshotIsReservedUploadedInPartsAndCommittedWithItsChecksum() async throws {
        let c = try await clients()
        await c.fake.setUploadPartSize(40)
        let png = FakeASC.samplePNG
        let reserved = try #require(try await c.write.send(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots",
                                                           body: try json(reservation()))?.data.first)
        guard case let .array(operations)? = reserved.attributes["uploadOperations"] else { Issue.record("no upload operations"); return }
        #expect(operations.count == 2)
        for operation in operations {
            guard case let .object(fields) = operation, let url = fields["url"]?.stringValue.flatMap(URL.init(string:)),
                  let offset = fields["offset"]?.intValue, let length = fields["length"]?.intValue else {
                Issue.record("unusable operation \(operation)")
                return
            }
            #expect(url.host == FakeASC.uploadHost)
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            put.httpBody = png.subdata(in: offset..<(offset + length))
            let (_, response) = try await c.fake.send(put)
            #expect(response.statusCode == 200)
        }
        let path = "/v1/subscriptionAppStoreReviewScreenshots/\(reserved.id)"
        func commit(_ checksum: String) throws -> Data {
            try json(["data": ["type": "subscriptionAppStoreReviewScreenshots", "id": reserved.id,
                               "attributes": ["uploaded": true, "sourceFileChecksum": checksum]]])
        }
        let wrong = try commit("00000000000000000000000000000000")
        await #expect(throws: ASCError.self) { _ = try await c.write.send(method: "PATCH", path: path, body: wrong) }
        _ = try await c.write.send(method: "PATCH", path: path, body: try commit(FakeASC.md5(png)))
        let shot = try #require(try await c.read.reviewScreenshot(of: .subscription("sub-spike-a")))
        #expect(shot.isDownloadable)
        #expect(shot.templateURL == FakeASC.imageTemplate(screenshotId: reserved.id))
        let second = try json(reservation())
        await #expect(throws: ASCError.self) {
            _ = try await c.write.send(method: "POST", path: "/v1/subscriptionAppStoreReviewScreenshots", body: second)
        }
        // A finished screenshot is no longer the client's to change (AppGuard); an unfinished reservation is deleted.
        await #expect(throws: ASCError.foreignResource(path)) { try await c.write.delete(path: path) }
        let unfinished = try #require(try await c.write.send(method: "POST", path: "/v1/inAppPurchaseAppStoreReviewScreenshots", body: try json([
            "data": ["type": "inAppPurchaseAppStoreReviewScreenshots", "attributes": ["fileName": "b.png", "fileSize": png.count],
                     "relationships": ["inAppPurchaseV2": ["data": ["type": "inAppPurchases", "id": "iap-spike"]]]]]))?.data.first?.id)
        #expect(try await c.read.reviewScreenshot(of: .iap("iap-spike"))?.deliveryState == "AWAITING_UPLOAD")
        try await c.write.delete(path: "/v1/inAppPurchaseAppStoreReviewScreenshots/\(unfinished)")
        #expect(try await c.read.reviewScreenshot(of: .iap("iap-spike")) == nil)
        let uploads = await c.fake.assetRequests()
        #expect(uploads.map(\.method) == ["PUT", "PUT"])
        #expect(uploads.allSatisfy { !$0.hadAuthorization && $0.host == FakeASC.uploadHost })
    }

    @Test func theImageHostServesTheSamplePNGWithoutAToken() async throws {
        let fake = FakeASC(model: FakeSeed.cloneSource(), now: { Sample.fixedNow })
        let image = try #require(URL(string: "https://\(FakeASC.imageHost)/image/thumb/fake/shot-spike-a/1x1bb.png"))
        let (data, response) = try await fake.send(URLRequest(url: image))
        #expect(response.statusCode == 200 && data == FakeASC.samplePNG)
        let elsewhere = try #require(URL(string: "https://\(FakeASC.imageHost)/elsewhere.png"))
        let (_, missing) = try await fake.send(URLRequest(url: elsewhere))
        #expect(missing.statusCode == 404)
        #expect(await fake.assetRequests().allSatisfy { !$0.hadAuthorization })
    }

    @Test func theCloneSourceCarriesEverythingAClonesCopies() async throws {
        let c = try await clients(FakeSeed.cloneSource())
        let group = try #require(try await c.read.subscriptionGroups(appId: FakeSeed.appId).first { $0.id == "grp-spike" })
        let yearly = try #require(try await c.read.subscriptions(group: group).first { $0.ascId == "sub-spike-a" })
        #expect(yearly.familySharable == true && yearly.groupLevel == 1)
        #expect(yearly.reviewNote == "Synthetic review note for the yearly plan")
        #expect(try await c.read.subscriptionAvailability(subscriptionId: "sub-spike-a")?.availableInNewTerritories == true)
        let lifetime = try #require(try await c.read.inAppPurchases(appId: FakeSeed.appId).first { $0.ascId == "iap-spike" })
        #expect(lifetime.familySharable == false && lifetime.reviewNote == "Synthetic review note for the lifetime purchase")
        #expect(try await c.read.iapAvailability(iapId: "iap-spike")?.territories.count == 6)
        #expect(try await c.read.reviewScreenshot(of: .iap("iap-spike"))?.isDownloadable == true)
        let model = await c.fake.model
        #expect(Set(model.localizations.filter { $0.versionId == "sver-spike-a-1" }.map(\.locale)) == ["cs", "en-US"])
    }
}
