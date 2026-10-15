import Foundation
import Testing
import Domain
@testable import ASCClient
import PurserTestSupport

private func canonical(_ data: Data?) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data ?? Data())
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

private func canonical(_ text: String) throws -> String { try canonical(Data(text.utf8)) }

private func document(_ json: String) throws -> JSONAPIDocument { try JSONDecoder().decode(JSONAPIDocument.self, from: Data(json.utf8)) }

private func route(_ r: (method: String, path: String)) -> String { "\(r.method) \(r.path)" }

@Suite("Metadata version writes (L3)")
struct MetadataVersionWriteTests {
    @Test func bodiesNameOnlyTheOwner() throws {
        let cases: [(LocalizationOwner, String)] = [
            (.subscription("6500000001"),
             #"{"data":{"type":"subscriptionVersions","relationships":{"subscription":{"data":{"type":"subscriptions","id":"6500000001"}}}}}"#),
            (.iap("6600000001"),
             #"{"data":{"type":"inAppPurchaseVersions","relationships":{"inAppPurchase":{"data":{"type":"inAppPurchases","id":"6600000001"}}}}}"#),
            (.group("7000000001"),
             #"{"data":{"type":"subscriptionGroupVersions","relationships":{"subscriptionGroup":{"data":{"type":"subscriptionGroups","id":"7000000001"}}}}}"#),
        ]
        for (owner, golden) in cases {
            #expect(try canonical(WriteBodies.createMetadataVersion(owner: owner).data()) == canonical(golden))
            #expect(try WriteBodies.body(for: .createMetadataVersion(owner: owner)) == WriteBodies.createMetadataVersion(owner: owner))
        }
    }

    @Test func theBodyMatchesWhatAppGuardChecks() {
        // The relationship and type a version POST names are the ones AppGuard.versionParents requires.
        for kind in LocalizationOwnerKind.allCases {
            let parent = AppGuard.versionParents[WriteBodies.versionType(kind)]
            #expect(parent?.relationship == WriteBodies.versionOwner(kind).relationship)
            #expect(parent?.type == WriteBodies.versionOwner(kind).type)
        }
    }

    @Test func pathsForEveryOwnerKind() {
        #expect(route(WritePaths.metadataVersion(.subscription)) == "POST /v1/subscriptionVersions")
        #expect(route(WritePaths.metadataVersion(.iap)) == "POST /v1/inAppPurchaseVersions")
        #expect(route(WritePaths.metadataVersion(.group)) == "POST /v1/subscriptionGroupVersions")
        #expect(route(WritePaths.request(for: .createMetadataVersion(owner: .iap("6600000001")))) == "POST /v1/inAppPurchaseVersions")
    }

    @Test func responseMapsTheVersion() throws {
        let owner = LocalizationOwner.group("7000000001")
        let version = try WriteResponses.metadataVersion(try document("""
        {"data":{"type":"subscriptionGroupVersions","id":"gv-4","attributes":{"version":4,"state":"PREPARE_FOR_SUBMISSION"}},
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/subscriptionGroupVersions/gv-4"}}
        """), owner: owner)
        #expect(version == MetadataVersion(ascId: "gv-4", owner: owner, number: 4, state: .prepareForSubmission))
    }

    @Test func aResponseWithoutNumberOrStateOrOfAnotherTypeIsADecodingError() throws {
        let owner = LocalizationOwner.subscription("6500000001")
        #expect(throws: ASCError.decoding("subscriptionVersions sv-1: version or state is missing")) {
            try WriteResponses.metadataVersion(try document(#"{"data":{"type":"subscriptionVersions","id":"sv-1","attributes":{"version":2}}}"#),
                                               owner: owner)
        }
        #expect(throws: ASCError.decoding("subscriptionVersions: response has no primary resource")) {
            try WriteResponses.metadataVersion(try document(#"{"data":{"type":"inAppPurchaseVersions","id":"iv-1","attributes":{"version":2,"state":"PREPARE_FOR_SUBMISSION"}}}"#),
                                               owner: owner)
        }
        #expect(throws: ASCError.decoding("subscriptionVersions: response has no primary resource")) {
            try WriteResponses.metadataVersion(nil, owner: owner)
        }
    }

    @Test func theLiveClientPostsTheBodyAndLearnsTheNewId() async throws {
        let transport = QueueHTTPTransport([(201, """
        {"data":{"type":"subscriptionVersions","id":"sv-900","attributes":{"version":3,"state":"PREPARE_FOR_SUBMISSION"},
                 "relationships":{"subscription":{"data":{"type":"subscriptions","id":"6500000001"}}}},
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/subscriptionVersions/sv-900"}}
        """)])
        let http = try await WriteTestClients.http(transport: transport, readOnly: false, products: ["6500000001"])
        let owner = LocalizationOwner.subscription("6500000001")
        let version = try await LiveASCClient(http: http).createMetadataVersion(owner: owner)
        #expect(version == MetadataVersion(ascId: "sv-900", owner: owner, number: 3, state: .prepareForSubmission))
        let sent = await transport.requests
        #expect(sent.count == 1)
        #expect(sent.first?.httpMethod == "POST")
        #expect(sent.first?.url?.path == "/v1/subscriptionVersions")
        #expect(try canonical(sent.first?.httpBody) == canonical(try WriteBodies.createMetadataVersion(owner: owner).data()))
        // ASCHTTPClient step 6: the created version is a known child now, so its texts can be read and written.
        try await http.appGuard.check(method: "GET", path: "/v1/subscriptionVersions/sv-900/localizations", body: nil)
    }

    @Test func aForeignOwnerIsRefusedBeforeAnythingIsSent() async throws {
        let transport = QueueHTTPTransport([])
        let http = try await WriteTestClients.http(transport: transport, readOnly: false, products: ["6500000001"])
        await #expect(throws: ASCError.foreignResource("/v1/subscriptionVersions")) {
            _ = try await LiveASCClient(http: http).createMetadataVersion(owner: .subscription("6500000999"))
        }
        #expect(await transport.requests.isEmpty)
    }
}
