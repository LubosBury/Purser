import Foundation
import Testing
@testable import ASCClient
import Domain
import PurserTestSupport

/// Decodes every response recorded by Tools/record-fixture.sh (spikes S0/SC). Skipped while nothing is recorded.
@Suite struct RecordedFixturesTests {
    struct Recorded {
        var name: String
        var path: String
        var status: Int
        var body: Data
    }

    private struct Meta: Decodable {
        var path: String
        var status: Int
    }

    static func load() throws -> [Recorded] {
        let directory = Fixtures.root.appendingPathComponent("asc/recorded", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return try files.filter { $0.lastPathComponent.hasSuffix(".meta.json") }.sorted { $0.path < $1.path }.map { metaURL in
            let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaURL))
            let name = String(metaURL.lastPathComponent.dropLast(".meta.json".count))
            let body = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
            return Recorded(name: name, path: meta.path, status: meta.status, body: body)
        }
    }

    static var available: Bool {
        ((try? load()) ?? []).contains { $0.status == 200 }
    }

    /// Subscriptions whose recorded planAvailabilities contain MONTHLY.
    static func monthlySubscriptions(_ recorded: [Recorded]) throws -> Set<String> {
        var result: Set<String> = []
        for item in recorded where item.status == 200 {
            if let match = item.path.wholeMatch(of: /\/v1\/subscriptions\/([^\/]+)\/planAvailabilities/) {
                let document = try JSONDecoder().decode(JSONAPIDocument.self, from: item.body)
                if ASCMapping.hasMonthlyPlan([document]) { result.insert(String(match.1)) }
            }
        }
        return result
    }

    @Test(.enabled(if: RecordedFixturesTests.available))
    func everyRecordedResponseMapsToDomainValues() throws {
        let recorded = try Self.load()
        let monthly = try Self.monthlySubscriptions(recorded)
        for item in recorded where item.status == 200 {
            let document = try JSONDecoder().decode(JSONAPIDocument.self, from: item.body)
            func subscription(_ id: Substring) -> SubscriptionInfo {
                SubscriptionInfo(ascId: String(id), productId: "recorded", name: "recorded", period: .oneYear, state: .approved,
                                 groupId: "group", groupName: "group", availableTerritories: [],
                                 monthlyPlanAvailable: monthly.contains(String(id)))
            }
            let path = item.path
            if path.wholeMatch(of: /\/v1\/apps\/[^\/]+/) != nil {
                _ = try ASCMapping.app(document)
            } else if path == "/v1/territories" || path.hasSuffix("/availableTerritories") {
                #expect(try !ASCMapping.territories([document]).isEmpty, "\(item.name)")
            } else if path.hasSuffix("/subscriptionGroups") {
                _ = ASCMapping.groups([document])
            } else if path.hasSuffix("/subscriptions") {
                _ = try ASCMapping.subscriptionHeaders([document])
            } else if let match = path.wholeMatch(of: /\/v1\/subscriptions\/([^\/]+)\/prices/) {
                let rows = try ASCMapping.regularPrices([document], subscription: subscription(match.1))
                #expect(rows.count == document.data.count, "\(item.name)")
            } else if let match = path.wholeMatch(of: /\/v1\/subscriptions\/([^\/]+)\/introductoryOffers/) {
                _ = try ASCMapping.introductoryOffers([document], subscription: subscription(match.1))
            } else if let match = path.wholeMatch(of: /\/v1\/subscriptions\/([^\/]+)\/pricePoints/) {
                _ = try ASCMapping.pricePoints([document], productAscId: String(match.1), planType: .upfront)
            } else if let match = path.wholeMatch(of: /\/v2\/inAppPurchases\/([^\/]+)\/pricePoints/) {
                _ = try ASCMapping.pricePoints([document], productAscId: String(match.1), planType: nil)
            } else if path.hasSuffix("/inAppPurchasesV2") {
                _ = ASCMapping.inAppPurchases([document])
            } else if path.hasSuffix("/manualPrices") {
                _ = try ASCMapping.iapManualPrices([document])
            } else if path.wholeMatch(of: /\/v1\/subscriptionPromotionalOffers\/[^\/]+\/prices/) != nil {
                #expect(document.data.allSatisfy { $0.relatedID("territory") != nil }, "\(item.name)")
            } else if path.hasSuffix("/promotionalOffers") {
                #expect(document.data.allSatisfy { $0.string("offerCode") != nil }, "\(item.name)")
            }
        }
    }
}
