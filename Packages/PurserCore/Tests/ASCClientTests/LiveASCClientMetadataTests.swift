import Foundation
import Testing
import ASCClient
import Domain
import PurserTestSupport

@Suite struct LiveASCClientMetadataTests {
    /// The routed "Fruit Journal" fixtures plus the three versions reads; the products and the group are listed first so AppGuard knows them.
    private func client(_ transport: FakeTransport? = nil) async throws -> (LiveASCClient, FakeTransport) {
        let t = try transport ?? LiveASCClientReadingTests.routedTransport()
        t.on("GET", "/v1/subscriptions/6500000001/versions", try .fixture("subscriptionVersions-6500000001"))
        t.on("GET", "/v2/inAppPurchases/6600000001/versions", try .fixture("inAppPurchaseVersions-6600000001"))
        t.on("GET", "/v1/subscriptionGroups/7000000001/versions", try .fixture("subscriptionGroupVersions-7000000001"))
        let client = try LiveASCClientReadingTests.makeClient(t)
        let group = try #require(try await client.subscriptionGroups(appId: "6400000001").first)
        _ = try await client.subscriptions(group: group)
        _ = try await client.inAppPurchases(appId: "6400000001")
        return (client, t)
    }

    private func row(_ id: String, _ owner: LocalizationOwner, _ version: String, _ locale: String, _ text: LocalizationText) -> LocalizationRow {
        LocalizationRow(ascId: id, owner: owner, versionId: version, locale: locale, text: text)
    }

    @Test func readsSubscriptionVersionsAndKeepsTheTextsOfLiveAndPending() async throws {
        let (client, transport) = try await client()
        let owner = LocalizationOwner.subscription("6500000001")
        let metadata = try await client.metadata(owner: owner)
        #expect(metadata.versions == [
            MetadataVersion(ascId: "sver-1", owner: owner, number: 1, state: .replacedWithNewVersion),
            MetadataVersion(ascId: "sver-2", owner: owner, number: 2, state: .approved),
            MetadataVersion(ascId: "sver-3", owner: owner, number: 3, state: .prepareForSubmission),
        ])
        #expect(metadata.liveVersion?.ascId == "sver-2")
        #expect(metadata.pendingVersion?.ascId == "sver-3")
        #expect(metadata.localizations == [
            row("sloc-2-cs", owner, "sver-2", "cs", LocalizationText(name: "Ovoce ročně", description: "Ovoce na celý rok")),
            row("sloc-2-en", owner, "sver-2", "en-US", LocalizationText(name: "Fruit Yearly", description: "Fruit all year")),
            row("sloc-3-cs", owner, "sver-3", "cs", LocalizationText(name: "Ovoce ročně", description: "Ovoce na celý rok")),
            row("sloc-3-de", owner, "sver-3", "de-DE", LocalizationText(name: "Obst jährlich", description: nil)),
            row("sloc-3-en", owner, "sver-3", "en-US", LocalizationText(name: "Fruit Yearly Plus", description: "All the fruit, all year")),
        ])
        let request = try #require(transport.requests.last)
        #expect(request.path == "/v1/subscriptions/6500000001/versions")
        #expect(request.queryValue("include") == "localizations")
        #expect(request.queryValue("limit[localizations]") == "50")
        #expect(request.queryValue("limit") == "200")
        #expect(transport.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func readsInAppPurchaseVersionsUnderV2() async throws {
        let (client, _) = try await client()
        let owner = LocalizationOwner.iap("6600000001")
        let metadata = try await client.metadata(owner: owner)
        #expect(metadata.liveVersion == MetadataVersion(ascId: "iver-1", owner: owner, number: 1, state: .approved))
        #expect(metadata.pendingVersion == nil)
        #expect(metadata.localizations == [
            row("iloc-1-en", owner, "iver-1", "en-US", LocalizationText(name: "Fruit Lifetime", description: "Every fruit, forever")),
        ])
    }

    @Test func groupTextsCarryTheCustomAppName() async throws {
        let (client, _) = try await client()
        let owner = LocalizationOwner.group("7000000001")
        let metadata = try await client.metadata(owner: owner)
        #expect(metadata.pendingVersion?.state == .waitingForReview)
        #expect(metadata.localizations.map(\.text) == [
            LocalizationText(name: "Fruit Premium", customAppName: "Fruit Journal"),
            LocalizationText(name: "Fruit Premium", customAppName: "Fruit Journal Plus"),
        ])
        #expect(metadata.localizations.allSatisfy { $0.text.description == nil })
    }

    @Test func aVersionWithFiftyIncludedTextsIsReadAgainInFull() async throws {
        let locales = (0..<51).map { String(format: "x%02d", $0) }
        func text(_ locale: String) -> String {
            #"{"type":"subscriptionLocalizations","id":"loc-\#(locale)","attributes":{"name":"Name \#(locale)","locale":"\#(locale)","description":"D"}}"#
        }
        let links = locales.prefix(50).map { #"{"type":"subscriptionLocalizations","id":"loc-\#($0)"}"# }.joined(separator: ",")
        let versions = """
        {"data":[{"type":"subscriptionVersions","id":"sver-9","attributes":{"version":1,"state":"APPROVED"},
          "relationships":{"localizations":{"data":[\(links)]}}}],
         "included":[\(locales.prefix(50).map(text).joined(separator: ","))],"links":{"self":"https://api.appstoreconnect.apple.com/x"}}
        """
        let all = #"{"data":[\#(locales.map(text).joined(separator: ","))],"links":{"self":"https://api.appstoreconnect.apple.com/y"}}"#
        let transport = try LiveASCClientReadingTests.routedTransport()
        let (client, _) = try await client(transport)
        transport.on("GET", "/v1/subscriptions/6500000001/versions", .json(versions))
        transport.on("GET", "/v1/subscriptionVersions/sver-9/localizations", .json(all))
        let metadata = try await client.metadata(owner: .subscription("6500000001"))
        #expect(metadata.localizations.count == 51)
        #expect(metadata.localizations.last?.locale == "x50")
        #expect(transport.requests.last?.path == "/v1/subscriptionVersions/sver-9/localizations")
        #expect(transport.requests.last?.queryValue("limit") == "200")
    }

    @Test func aVersionWithoutNumberOrAMissingTextIsADecodingError() async throws {
        let transport = try LiveASCClientReadingTests.routedTransport()
        let (client, _) = try await client(transport)
        transport.on("GET", "/v1/subscriptions/6500000001/versions",
                     .json(#"{"data":[{"type":"subscriptionVersions","id":"sver-x","attributes":{"state":"APPROVED"}}],"links":{"self":"https://api.appstoreconnect.apple.com/x"}}"#))
        await #expect(throws: ASCError.decoding("subscriptionVersions sver-x: missing version or state")) {
            _ = try await client.metadata(owner: .subscription("6500000001"))
        }
        transport.on("GET", "/v1/subscriptions/6500000001/versions",
                     .json(#"{"data":[{"type":"subscriptionVersions","id":"sver-y","attributes":{"version":1,"state":"APPROVED"},"relationships":{"localizations":{"data":[{"type":"subscriptionLocalizations","id":"gone"}]}}}],"links":{"self":"https://api.appstoreconnect.apple.com/x"}}"#))
        await #expect(throws: ASCError.decoding("subscriptionVersions sver-y: localization gone not included")) {
            _ = try await client.metadata(owner: .subscription("6500000001"))
        }
    }

    @Test func ownersOutsideTheAppAreRefused() async throws {
        let client = try LiveASCClientReadingTests.makeClient(try LiveASCClientReadingTests.routedTransport())
        await #expect(throws: ASCError.foreignResource("/v1/subscriptions/6500000001/versions")) {
            _ = try await client.metadata(owner: .subscription("6500000001"))
        }
        await #expect(throws: ASCError.foreignResource("/v1/subscriptionGroups/7000000001/versions")) {
            _ = try await client.metadata(owner: .group("7000000001"))
        }
    }
}
