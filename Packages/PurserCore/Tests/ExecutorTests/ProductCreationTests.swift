import Foundation
import Synchronization
import Testing
import ASCClient
import Audit
import Domain
import Executor
import PurserSecurity
import Store
import PurserTestSupport

private final class CountingGate: BiometricGate, Sendable {
    private let count = Mutex(0)
    var prompts: Int { count.withLock { $0 } }
    func authenticate(reason: String) async throws { count.withLock { $0 += 1 } }
}

private let spikeRequest = ProductCreationRequest.purserSpike

@Suite struct ProductCreationPlannerTests {
    @Test func spikePresetOnAnEmptyAppCreatesGroupProductsAndAvailability() {
        let steps = ProductCreationPlanner.steps(spikeRequest, existing: ExistingProducts())
        #expect(steps.first == .group(name: "Purser Spike"))
        #expect(steps.count == 11)   // group + 4 x (subscription, availability) + (non-consumable, availability)
        #expect(steps.contains(.subscription(NewSubscriptionProduct(productId: "SpikeYearlyC", name: "SpikeYearlyC", period: .oneYear))))
        #expect(steps.contains(.subscriptionAvailability(productId: "SpikeMonthly")))
        #expect(steps.suffix(2) == [.nonConsumable(NewNonConsumableProduct(productId: "PurserSpikeLifetime", name: "PurserSpikeLifetime")),
                                    .nonConsumableAvailability(productId: "PurserSpikeLifetime")])
    }

    @Test func whatAlreadyExistsIsNotCreatedAgain() {
        var existing = ExistingProducts()
        existing.groups["Purser Spike"] = "7000000001"
        existing.subscriptions["SpikeYearlyA"] = "6500000001"
        existing.nonConsumables["PurserSpikeLifetime"] = "6600000001"
        let steps = ProductCreationPlanner.steps(spikeRequest, existing: existing)
        #expect(!steps.contains(.group(name: "Purser Spike")))
        #expect(!steps.contains { if case let .subscription(s) = $0 { return s.productId == "SpikeYearlyA" } else { return false } })
        #expect(!steps.contains(.subscriptionAvailability(productId: "SpikeYearlyA")))
        #expect(!steps.contains(.nonConsumableAvailability(productId: "PurserSpikeLifetime")))
        #expect(steps.count == 6)   // 3 x (subscription, availability)
    }

    @Test func invalidRequestsAreReported() {
        var request = ProductCreationRequest(groupName: "", subscriptions: [
            NewSubscriptionProduct(productId: "bad id", name: "A", period: .oneYear),
            NewSubscriptionProduct(productId: "dup", name: "", period: .oneYear),
            NewSubscriptionProduct(productId: "dup", name: "B", period: .oneMonth),
        ], nonConsumables: [NewNonConsumableProduct(productId: "dup", name: "L")])
        let problems = ProductCreationPlanner.problems(request)
        #expect(problems.contains { $0.contains("group name") })
        #expect(problems.contains { $0.contains("bad id") })
        #expect(problems.contains { $0.contains("dup") && $0.contains("more than once") })
        #expect(problems.contains { $0.contains("needs a name") })
        request = ProductCreationRequest(groupName: nil, subscriptions: [], nonConsumables: [])
        #expect(ProductCreationPlanner.problems(request) == ["There is nothing to create."])
        #expect(ProductCreationPlanner.problems(spikeRequest).isEmpty)
    }
}

@Suite struct ProductCreatorTests {
    private struct Harness {
        let transport: QueueHTTPTransport
        let reader: ScriptedReader
        let audit: AuditLog
        let gate = CountingGate()
        let creator: ProductCreator

        init(responses: [(status: Int, body: String)], readOnly: Bool = false, script: ScriptedReader.Script = ScriptedReader.Script()) async throws {
            transport = QueueHTTPTransport(responses)
            reader = ScriptedReader(script)
            let database = try WorkspaceDatabase.inMemory()
            audit = AuditLog(database: database, actor: { "001234.synthetic-owner.0001" }, now: { Sample.fixedNow })
            let budget = RateBudget(now: { Sample.fixedNow }, sleep: { _ in })
            let http = try await WriteTestClients.http(transport: transport, readOnly: readOnly, products: [], budget: budget,
                                                       appGuard: AppGuard(appId: Sample.appId), now: { Sample.fixedNow })
            creator = ProductCreator(config: Sample.config(), http: http, reader: reader, audit: audit, budget: budget, gate: gate)
        }

        func sent() async -> [(path: String, body: [String: Any])] {
            await transport.requests.map { request in
                let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
                return (request.url?.path ?? "", body)
            }
        }
    }

    private static func created(_ type: String, _ id: String) -> (status: Int, body: String) {
        (201, #"{"data":{"type":"\#(type)","id":"\#(id)"}}"#)
    }

    private static let oneSubscription = ProductCreationRequest(
        groupName: "Purser Spike",
        subscriptions: [NewSubscriptionProduct(productId: "SpikeYearlyA", name: "SpikeYearlyA", period: .oneYear)],
        nonConsumables: [NewNonConsumableProduct(productId: "PurserSpikeLifetime", name: "PurserSpikeLifetime")])

    @Test func createsGroupSubscriptionAvailabilityAndNonConsumableInOrder() async throws {
        let h = try await Harness(responses: [
            Self.created("subscriptionGroups", "g-1"), Self.created("subscriptions", "s-1"), Self.created("subscriptionAvailabilities", "a-1"),
            Self.created("inAppPurchases", "i-1"), Self.created("inAppPurchaseAvailabilities", "ia-1"),
        ])
        let reports = try await h.creator.create(Self.oneSubscription)
        #expect(reports.map(\.outcome) == [.created(ascId: "g-1"), .created(ascId: "s-1"), .created(ascId: "a-1"),
                                           .created(ascId: "i-1"), .created(ascId: "ia-1")])
        #expect(h.gate.prompts == 1)
        let sent = await h.sent()
        #expect(sent.map(\.path) == ["/v1/subscriptionGroups", "/v1/subscriptions", "/v1/subscriptionAvailabilities",
                                     "/v2/inAppPurchases", "/v1/inAppPurchaseAvailabilities"])
        let subscription = try #require(sent[1].body["data"] as? [String: Any])
        let attributes = try #require(subscription["attributes"] as? [String: Any])
        #expect(attributes["productId"] as? String == "SpikeYearlyA")
        #expect(attributes["subscriptionPeriod"] as? String == "ONE_YEAR")
        let relationships = try #require(subscription["relationships"] as? [String: Any])
        #expect(((relationships["group"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String == "g-1")
        let availability = try #require((sent[2].body["data"] as? [String: Any])?["relationships"] as? [String: Any])
        #expect(((availability["subscription"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String == "s-1")
        #expect(((availability["availableTerritories"] as? [String: Any])?["data"] as? [[String: Any]])?.count == 3)
        let iap = try #require((sent[3].body["data"] as? [String: Any])?["attributes"] as? [String: Any])
        #expect(iap["inAppPurchaseType"] as? String == "NON_CONSUMABLE")
    }

    @Test func everyRequestIsAuditedBeforeItLeavesAndAfterItReturns() async throws {
        let h = try await Harness(responses: [
            Self.created("subscriptionGroups", "g-1"), Self.created("subscriptions", "s-1"), Self.created("subscriptionAvailabilities", "a-1"),
            Self.created("inAppPurchases", "i-1"), Self.created("inAppPurchaseAvailabilities", "ia-1"),
        ])
        _ = try await h.creator.create(Self.oneSubscription)
        let types = try h.audit.events(after: 0, limit: 100).map(\.type)
        #expect(types == Array(repeating: [AuditEventType.httpSent, .httpReceived], count: 5).flatMap { $0 })
    }

    @Test func aRefusedGroupSkipsItsSubscriptionsButNotTheNonConsumable() async throws {
        let h = try await Harness(responses: [
            (409, #"{"errors":[{"status":"409","code":"ENTITY_ERROR","title":"Refused","detail":"Synthetic refusal"}]}"#),
            Self.created("inAppPurchases", "i-1"), Self.created("inAppPurchaseAvailabilities", "ia-1"),
        ])
        let reports = try await h.creator.create(Self.oneSubscription)
        #expect(reports.count == 5)
        if case .failed = reports[0].outcome {} else { Issue.record("group should fail: \(reports[0])") }
        if case .skipped = reports[1].outcome {} else { Issue.record("subscription should be skipped: \(reports[1])") }
        if case .skipped = reports[2].outcome {} else { Issue.record("availability should be skipped: \(reports[2])") }
        #expect(reports[3].outcome == .created(ascId: "i-1"))
        #expect(await h.sent().map(\.path) == ["/v1/subscriptionGroups", "/v2/inAppPurchases", "/v1/inAppPurchaseAvailabilities"])
    }

    @Test func existingProductsAreSkippedWithoutAnyRequestOrTouchID() async throws {
        var script = ScriptedReader.Script()
        script.groups = [ASCSubscriptionGroup(id: "7000000001", referenceName: "Purser Spike")]
        script.subscriptions = [Sample.subscription("6500000001", productId: "SpikeYearlyA")]
        script.iaps = [Sample.iap()]
        let h = try await Harness(responses: [], script: script)
        let request = ProductCreationRequest(
            groupName: "Purser Spike",
            subscriptions: [NewSubscriptionProduct(productId: "SpikeYearlyA", name: "SpikeYearlyA", period: .oneYear)],
            nonConsumables: [NewNonConsumableProduct(productId: Sample.iap().productId, name: "Lifetime")])
        #expect(try await h.creator.create(request).isEmpty)
        #expect(h.gate.prompts == 0)
        #expect(await h.sent().isEmpty)
    }

    @Test func aSubscriptionIsAddedToAnExistingGroup() async throws {
        var script = ScriptedReader.Script()
        script.groups = [ASCSubscriptionGroup(id: "7000000001", referenceName: "Purser Spike")]
        script.subscriptions = []
        let h = try await Harness(responses: [Self.created("subscriptions", "s-9"), Self.created("subscriptionAvailabilities", "a-9")], script: script)
        let request = ProductCreationRequest(groupName: "Purser Spike",
                                             subscriptions: [NewSubscriptionProduct(productId: "SpikeYearlyB", name: "SpikeYearlyB", period: .oneYear)],
                                             nonConsumables: [])
        let reports = try await h.creator.create(request)
        #expect(reports.map(\.outcome) == [.created(ascId: "s-9"), .created(ascId: "a-9")])
        let relationships = try #require(((await h.sent())[0].body["data"] as? [String: Any])?["relationships"] as? [String: Any])
        #expect(((relationships["group"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String == "7000000001")
    }

    @Test func invalidRequestAndWrongAppBindingSendNothing() async throws {
        let h = try await Harness(responses: [])
        await #expect(throws: ProductCreationError.self) {
            _ = try await h.creator.create(ProductCreationRequest(groupName: nil, subscriptions: [], nonConsumables: []))
        }
        h.reader.update { $0.app = ASCApp(id: Sample.appId, bundleId: "com.example.other", name: "Other") }
        await #expect(throws: ProductCreationError.self) { _ = try await h.creator.create(Self.oneSubscription) }
        #expect(await h.sent().isEmpty)
        #expect(h.gate.prompts == 0)
    }

    @Test func aReadOnlyClientCreatesNothing() async throws {
        let h = try await Harness(responses: [], readOnly: true)
        let reports = try await h.creator.create(Self.oneSubscription)
        #expect(reports.allSatisfy { if case .created = $0.outcome { return false } else { return true } })
        #expect(await h.sent().isEmpty)
    }
}
