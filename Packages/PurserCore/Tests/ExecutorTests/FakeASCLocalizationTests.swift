import Foundation
import Testing
import Domain
import ASCClient
import PurserTestSupport

/// A signed GET straight to FakeASC (FakeASC checks the token shape, not the signature).
private func get(_ fake: FakeASC, _ path: String, _ query: [String: String] = [:]) async throws -> (status: Int, document: JSONAPIDocument?) {
    var components = URLComponents(string: "https://api.appstoreconnect.apple.com\(path)")!
    if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    var request = URLRequest(url: components.url!)
    request.httpMethod = "GET"
    request.setValue("Bearer " + (try WriteTestClients.signer().token(scope: nil, now: Date())), forHTTPHeaderField: "Authorization")
    let (data, response) = try await fake.send(request)
    guard response.statusCode == 200 else { return (response.statusCode, nil) }
    return (200, try JSONDecoder().decode(JSONAPIDocument.self, from: data))
}

private let withTexts = ["include": "localizations", "limit[localizations]": "50", "limit": "200"]

@Suite("FakeASC localizations")
struct FakeASCLocalizationTests {
    let clock = TestClock.at("2026-10-09T08:00:00Z")

    func makeFake(_ model: FakeModel = FakeSeed.fruitJar()) -> FakeASC { FakeASC(model: model, now: clock.nowFunction) }

    @Test func servesVersionsWithTheirTextsForEveryOwnerKind() async throws {
        let fake = makeFake()
        let subscription = try #require(try await get(fake, "/v1/subscriptions/sub-y/versions", withTexts).document)
        let version = try #require(subscription.data.first)
        #expect(subscription.data.count == 1)
        #expect(version.type == "subscriptionVersions")
        #expect(version.id == "ver-sub-y-1")
        #expect(version.int("version") == 1)
        #expect(version.string("state") == "APPROVED")
        #expect(version.relationships["localizations"]?.data?.map(\.id) == ["loc-sub-y-1-cs", "loc-sub-y-1-en-US"])
        let cs = try #require(subscription.includedResource(type: "subscriptionLocalizations", id: "loc-sub-y-1-cs"))
        #expect(cs.string("locale") == "cs")
        #expect(cs.string("name") == "Ročně")
        #expect(cs.string("description") == "Všechno ovoce na celý rok")

        let iap = try #require(try await get(fake, "/v2/inAppPurchases/iap-life/versions", withTexts).document)
        #expect(iap.data.map(\.type) == ["inAppPurchaseVersions"])
        #expect(iap.included.map(\.type) == ["inAppPurchaseLocalizations"])

        let group = try #require(try await get(fake, "/v1/subscriptionGroups/grp-1/versions", withTexts).document)
        #expect(group.data.map(\.type) == ["subscriptionGroupVersions"])
        let premium = try #require(group.includedResource(type: "subscriptionGroupLocalizations", id: "loc-grp-1-1-en-US"))
        #expect(premium.string("customAppName") == "FruitJar")
        #expect(premium.attributes["description"] == nil)

        let draft = try #require(try await get(fake, "/v1/subscriptions/sub-n/versions", withTexts).document)
        #expect(draft.data.first?.string("state") == "PREPARE_FOR_SUBMISSION")
    }

    @Test func withoutTheIncludeVersionsCarryNoTexts() async throws {
        let document = try #require(try await get(makeFake(), "/v1/subscriptions/sub-y/versions", ["limit": "200"]).document)
        #expect(document.data.first?.relationships["localizations"] == nil)
        #expect(document.included.isEmpty)
    }

    @Test func theIncludeIsCappedAtFiftyAndTheVersionTextsListEverything() async throws {
        var model = FakeSeed.fruitJar()
        for index in 0..<51 {
            model.localizations.append(FakeLocalization(id: "loc-x-\(index)", versionId: "ver-sub-y-1", locale: String(format: "x%02d", index),
                                                        text: LocalizationText(name: "Name \(index)")))
        }
        let fake = makeFake(model)
        let versions = try #require(try await get(fake, "/v1/subscriptions/sub-y/versions", withTexts).document)
        #expect(versions.data.first?.relationships["localizations"]?.data?.count == 50)
        #expect(versions.included.count == 50)
        let texts = try #require(try await get(fake, "/v1/subscriptionVersions/ver-sub-y-1/localizations", ["limit": "200"]).document)
        #expect(texts.data.count == 53)
        #expect(texts.data.allSatisfy { $0.type == "subscriptionLocalizations" })
        #expect(texts.data.first { $0.id == "loc-x-0" }?.attributes["description"] == .null)
    }

    @Test func unknownOwnersAndVersionsAreNotFoundAndAnOwnerWithoutVersionsIsEmpty() async throws {
        let fake = makeFake()
        #expect(try await get(fake, "/v1/subscriptions/sub-x/versions", withTexts).status == 404)
        #expect(try await get(fake, "/v1/subscriptionGroups/grp-x/versions", withTexts).status == 404)
        #expect(try await get(fake, "/v1/inAppPurchaseVersions/ver-sub-y-1/localizations").status == 404)
        let monthly = try #require(try await get(fake, "/v1/subscriptions/sub-m/versions", withTexts).document)
        #expect(monthly.data.isEmpty)
        #expect(await fake.writeRequests().isEmpty)
    }
}
