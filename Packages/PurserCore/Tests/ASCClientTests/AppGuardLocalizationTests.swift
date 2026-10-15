import Foundation
import Testing
import ASCClient

private func data(_ json: String) -> Data { Data(json.utf8) }

private func localization(_ collection: String, versionType: String, version: String) -> Data {
    data(#"{"data":{"type":"\#(collection)","attributes":{"name":"Ovoce","locale":"cs"},"relationships":{"version":{"data":{"type":"\#(versionType)","id":"\#(version)"}}}}}"#)
}

private func update(_ collection: String, id: String) -> Data {
    data(#"{"data":{"type":"\#(collection)","id":"\#(id)","attributes":{"name":"Ovoce"}}}"#)
}

private func newVersion(_ collection: String, relationship: String, type: String, id: String) -> Data {
    data(#"{"data":{"type":"\#(collection)","relationships":{"\#(relationship)":{"data":{"type":"\#(type)","id":"\#(id)"}}}}}"#)
}

@Suite struct AppGuardLocalizationTests {
    func guardian() async -> AppGuard {
        let guardian = AppGuard(appId: "6400000001")
        await guardian.allowProducts(["6500000001", "6600000001"])
        await guardian.allowChildren(["7000000001", "ver-1", "ver-g", "loc-1"])
        return guardian
    }

    @Test func aLocalizationPostMustNameAKnownVersionOfItsOwnKind() async throws {
        let g = await guardian()
        try await g.check(method: "POST", path: "/v2/subscriptionLocalizations",
                          body: localization("subscriptionLocalizations", versionType: "subscriptionVersions", version: "ver-1"))
        try await g.check(method: "POST", path: "/v2/subscriptionGroupLocalizations",
                          body: localization("subscriptionGroupLocalizations", versionType: "subscriptionGroupVersions", version: "ver-g"))
        await #expect(throws: ASCError.foreignResource("/v2/subscriptionLocalizations")) {
            try await g.check(method: "POST", path: "/v2/subscriptionLocalizations",
                              body: localization("subscriptionLocalizations", versionType: "subscriptionVersions", version: "ver-9"))
        }
        await #expect(throws: ASCError.self) {
            try await g.check(method: "POST", path: "/v2/inAppPurchaseLocalizations",
                              body: localization("inAppPurchaseLocalizations", versionType: "subscriptionVersions", version: "ver-1"))
        }
        await #expect(throws: ASCError.self) {
            try await g.check(method: "POST", path: "/v1/subscriptionLocalizations",
                              body: localization("subscriptionLocalizations", versionType: "subscriptionVersions", version: "ver-1"))
        }
        await #expect(throws: ASCError.self) { try await g.check(method: "POST", path: "/v2/subscriptionLocalizations", body: nil) }
        await #expect(throws: ASCError.self) { try await g.check(method: "POST", path: "/v2/subscriptionLocalizations", body: data("not json")) }
    }

    @Test func patchOnlyForKnownIdsAndAMatchingBodyAndNeverADelete() async throws {
        let g = await guardian()
        try await g.check(method: "PATCH", path: "/v2/subscriptionLocalizations/loc-1", body: update("subscriptionLocalizations", id: "loc-1"))
        try await g.check(method: "GET", path: "/v2/subscriptionLocalizations/loc-1", body: nil)
        // L-D4: Purser never deletes a locale, not even a known one.
        await #expect(throws: ASCError.foreignResource("/v2/subscriptionLocalizations/loc-1")) {
            try await g.check(method: "DELETE", path: "/v2/subscriptionLocalizations/loc-1", body: nil)
        }
        await #expect(throws: ASCError.foreignResource("/v2/subscriptionLocalizations/loc-9")) {
            try await g.check(method: "PATCH", path: "/v2/subscriptionLocalizations/loc-9", body: update("subscriptionLocalizations", id: "loc-9"))
        }
        await #expect(throws: ASCError.self) {
            try await g.check(method: "PATCH", path: "/v2/subscriptionLocalizations/loc-1", body: update("subscriptionLocalizations", id: "loc-2"))
        }
        await #expect(throws: ASCError.self) {
            try await g.check(method: "PATCH", path: "/v2/subscriptionLocalizations/loc-1", body: update("inAppPurchaseLocalizations", id: "loc-1"))
        }
        await #expect(throws: ASCError.self) { try await g.check(method: "DELETE", path: "/v2/subscriptionLocalizations/loc-9", body: nil) }
        await #expect(throws: ASCError.self) { try await g.check(method: "PUT", path: "/v2/subscriptionLocalizations/loc-1", body: nil) }
        await #expect(throws: ASCError.self) {
            try await g.check(method: "PATCH", path: "/v2/subscriptionLocalizations/loc-1/version", body: update("subscriptionLocalizations", id: "loc-1"))
        }
    }

    @Test func aVersionPostMustNameAnAllowedProductOrAKnownGroup() async throws {
        let g = await guardian()
        try await g.check(method: "POST", path: "/v1/subscriptionVersions",
                          body: newVersion("subscriptionVersions", relationship: "subscription", type: "subscriptions", id: "6500000001"))
        try await g.check(method: "POST", path: "/v1/inAppPurchaseVersions",
                          body: newVersion("inAppPurchaseVersions", relationship: "inAppPurchase", type: "inAppPurchases", id: "6600000001"))
        try await g.check(method: "POST", path: "/v1/subscriptionGroupVersions",
                          body: newVersion("subscriptionGroupVersions", relationship: "subscriptionGroup", type: "subscriptionGroups", id: "7000000001"))
        await #expect(throws: ASCError.foreignResource("/v1/subscriptionVersions")) {
            try await g.check(method: "POST", path: "/v1/subscriptionVersions",
                              body: newVersion("subscriptionVersions", relationship: "subscription", type: "subscriptions", id: "6500000999"))
        }
        await #expect(throws: ASCError.self) {
            try await g.check(method: "POST", path: "/v1/subscriptionGroupVersions",
                              body: newVersion("subscriptionGroupVersions", relationship: "subscriptionGroup", type: "subscriptionGroups", id: "7000000999"))
        }
        await #expect(throws: ASCError.self) {
            try await g.check(method: "POST", path: "/v1/subscriptionVersions",
                              body: newVersion("subscriptionVersions", relationship: "subscription", type: "subscriptionGroups", id: "7000000001"))
        }
    }
}
