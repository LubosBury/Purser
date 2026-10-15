import Foundation
import Testing
import Domain
@testable import ASCClient

private func canonical(_ data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data)
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

private func canonical(_ json: String) throws -> String { try canonical(Data(json.utf8)) }

@Suite("Localization write bodies")
struct LocalizationWriteBodiesTests {
    @Test func aSubscriptionCreateNamesTheVersionAndSendsItsDescriptionOnly() throws {
        let body = WriteBodies.createLocalization(versionId: "ver-2", owner: .subscription("sub-1"), locale: "cs",
                                                  text: LocalizationText(name: "Ovoce ročně", description: "Všechno ovoce", customAppName: "ignored"))
        let golden = """
        {"data":{"type":"subscriptionLocalizations",
          "attributes":{"locale":"cs","name":"Ovoce ročně","description":"Všechno ovoce"},
          "relationships":{"version":{"data":{"type":"subscriptionVersions","id":"ver-2"}}}}}
        """
        #expect(try canonical(body.data()) == canonical(golden))
    }

    @Test func aGroupCreateSendsTheCustomAppNameNeverADescription() throws {
        let body = WriteBodies.createLocalization(versionId: "ver-g", owner: .group("grp-1"), locale: "en-US",
                                                  text: LocalizationText(name: "Fruit Premium", description: "ignored", customAppName: "Fruit"))
        let golden = """
        {"data":{"type":"subscriptionGroupLocalizations",
          "attributes":{"locale":"en-US","name":"Fruit Premium","customAppName":"Fruit"},
          "relationships":{"version":{"data":{"type":"subscriptionGroupVersions","id":"ver-g"}}}}}
        """
        #expect(try canonical(body.data()) == canonical(golden))
    }

    @Test func anUpdateLeavesOutNilFieldsAndTheLocale() throws {
        let iap = WriteBodies.updateLocalization(localizationId: "loc-5", owner: .iap("iap-1"), text: LocalizationText(name: "Lifetime"))
        #expect(try canonical(iap.data()) == canonical(#"{"data":{"type":"inAppPurchaseLocalizations","id":"loc-5","attributes":{"name":"Lifetime"}}}"#))
        let group = WriteBodies.updateLocalization(localizationId: "loc-6", owner: .group("grp-1"),
                                                   text: LocalizationText(name: "Premium", customAppName: "Fruit"))
        #expect(try canonical(group.data())
                == canonical(#"{"data":{"type":"subscriptionGroupLocalizations","id":"loc-6","attributes":{"name":"Premium","customAppName":"Fruit"}}}"#))
    }

    private func route(_ r: (method: String, path: String)) -> String { "\(r.method) \(r.path)" }

    @Test func pathsForEveryOwnerKind() {
        #expect(route(WritePaths.createLocalization(.subscription)) == "POST /v2/subscriptionLocalizations")
        #expect(route(WritePaths.createLocalization(.iap)) == "POST /v2/inAppPurchaseLocalizations")
        #expect(route(WritePaths.createLocalization(.group)) == "POST /v2/subscriptionGroupLocalizations")
        #expect(route(WritePaths.updateLocalization(.subscription, id: "loc-1")) == "PATCH /v2/subscriptionLocalizations/loc-1")
        #expect(route(WritePaths.updateLocalization(.iap, id: "loc-2")) == "PATCH /v2/inAppPurchaseLocalizations/loc-2")
        #expect(route(WritePaths.updateLocalization(.group, id: "loc-3")) == "PATCH /v2/subscriptionGroupLocalizations/loc-3")
    }

    @Test func theCreatedRowComesFromTheResponseWithTheRequestAsFallback() throws {
        let json = #"{"data":{"type":"subscriptionLocalizations","id":"loc-77","attributes":{"name":"Ovoce","locale":"cs"},"relationships":{"version":{"data":{"type":"subscriptionVersions","id":"ver-2"}}}}}"#
        let document = try JSONDecoder().decode(JSONAPIDocument.self, from: Data(json.utf8))
        let owner = LocalizationOwner.subscription("sub-1")
        let row = try WriteResponses.localizationRow(document, owner: owner, versionId: "ver-2", locale: "cs",
                                                     text: LocalizationText(name: "Ovoce", description: "Všechno ovoce"))
        #expect(row == LocalizationRow(ascId: "loc-77", owner: owner, versionId: "ver-2", locale: "cs",
                                       text: LocalizationText(name: "Ovoce", description: "Všechno ovoce")))
        #expect(throws: ASCError.self) {
            try WriteResponses.localizationRow(nil, owner: owner, versionId: "ver-2", locale: "cs", text: LocalizationText(name: "Ovoce"))
        }
    }
}
