import Foundation
import Testing
import Domain
import ASCClient
import Catalog
import Policy
import Planner
import Executor
import PurserTestSupport

/// Regular price changes through the real Planner, Executor, LiveASCClient and FakeASC (M2).
/// sub-n (yearly, MISSING_METADATA) gets regular 29.99, a paid intro 19.99 and a PAYG promo 24.99 in all six FruitJar
/// territories. FruitJar points cost 0.99 + i (i < 40), so every snap lands on an existing point:
/// decrease to 24.99 -> intro 19.99 * 24.99 / 29.99 = 16.66 -> 15.99, promo 0.6 * 24.99 = 14.99;
/// increase to 34.99 -> intro 23.32 -> 22.99, promo untouched.
@Suite("Regular price change order over FakeASC")
struct RegularChangeScenarioTests {
    static let territories: [TerritoryCode] = ["CZE", "DEU", "FRA", "GBR", "JPN", "USA"]
    static let promoId = "promo-sub-n-payg"
    static let injected = FakeFault.conflict(code: "ENTITY_ERROR", detail: "Injected scenario failure")

    static func model() -> FakeModel {
        var model = FakeSeed.fruitJar()
        for territory in territories {
            model.regularPrices.append(FakeRegularPrice(id: "price-sub-n-\(territory)-0", subscriptionId: "sub-n", territory: territory,
                                                        planType: .upfront, sendsPlanType: true, startDate: FakeSeed.seedStart,
                                                        preserved: false, pricePointId: "pp-sub-n-\(territory)-29"))
            model.intros.append(FakeIntro(id: "intro-sub-n-\(territory)", subscriptionId: "sub-n", territory: territory,
                                          planType: .upfront, mode: .payUpFront, duration: .oneYear, numberOfPeriods: 1,
                                          startDate: FakeSeed.seedStart, endDate: nil, pricePointId: "pp-sub-n-\(territory)-19",
                                          createdOn: FakeSeed.seedStart))
        }
        model.promos.append(FakePromo(id: promoId, subscriptionId: "sub-n", offerCode: "jar_payg_v1", name: "Jar PAYG",
                                      mode: .payAsYouGo, duration: .oneYear, numberOfPeriods: 1, planType: .upfront,
                                      prices: territories.map {
                                          FakePromoPrice(id: "promoprice-sub-n-\($0)", territory: $0, pricePointId: "pp-sub-n-\($0)-24")
                                      }))
        model.usedOfferCodes.insert("jar_payg_v1")
        return model
    }

    static func spec(newPrice: String, preserve: Bool?, start: CalendarDate) -> PlanSpec {
        .regular(RegularPlanSpec(subscriptionIds: ["sub-n"], planType: .upfront,
                                 prices: territories.map { TerritoryAmount(territory: $0, amount: Decimal(string: newPrice)!) },
                                 startDate: start, preserveCurrentPrice: preserve, skipIntroReplacement: [:], filter: PlanFilter(),
                                 promoRepricing: [promoId: .percentOfRegular(Decimal(string: "0.6")!)]))
    }

    struct Write: Equatable {
        var method: String
        var path: String
        var territory: String?
    }

    /// Applied writes in the order FakeASC received them; the territory comes from the body (relationship or point id)
    /// or, for a DELETE of a seeded intro, from its id.
    static func writes(_ h: ExecutorHarness) async -> [Write] {
        await h.fake.writeRequests().filter(\.applied).map { record in
            Write(method: record.method, path: record.path, territory: territory(record))
        }
    }

    static func territory(_ record: FakeRequestRecord) -> String? {
        if record.method == "DELETE", let last = record.path.split(separator: "-").last { return String(last) }
        guard let body = record.body, let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = root["data"] as? [String: Any], let relationships = data["relationships"] as? [String: Any] else { return nil }
        func related(_ name: String) -> String? {
            ((relationships[name] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
        }
        if let territory = related("territory") { return territory }
        if let point = related("subscriptionPricePoint") { return point.split(separator: "-").dropLast().last.map(String.init) }
        return nil
    }

    static func index(_ writes: [Write], _ method: String, _ path: String, _ territory: TerritoryCode) throws -> Int {
        try #require(writes.firstIndex { $0.method == method && $0.path == path && $0.territory == territory.rawValue },
                     "\(method) \(path) \(territory) missing in \(writes)")
    }

    func run(_ h: ExecutorHarness, _ spec: PlanSpec) async throws -> (planId: String, state: PlanState, draft: PlanDraft) {
        let snapshot = try await h.initialSync()
        let draft = try Planner(policy: PolicyEngine()).plan(spec, context: PlanningContext(snapshot: snapshot, config: h.config, today: h.today))
        #expect(draft.verdicts.filter { $0.severity == .block(.plan) }.isEmpty, "plan blocks: \(draft.verdicts)")
        let planId = try PlanPersistence(store: h.store, audit: h.audit, appBuild: "test")
            .saveDraft(draft, binding: PlanBinding(config: h.config), reason: "Regular change scenario test", replanOf: nil)
        let state = try await h.makeExecutor(policy: PolicyEngine()).apply(planId: planId, confirm: Confirm.accept)
        return (planId, state, draft)
    }

    func noIntroOrPromoAtOrAboveRegular(_ h: ExecutorHarness) async throws {
        let snapshot = try await h.initialSync()
        let verdicts = PolicyEngine().invariants(snapshot, today: h.today)
        #expect(!verdicts.contains { $0.rule == "I4" || $0.rule == "O5" }, "invariants: \(verdicts)")
    }

    @Test func decreaseWritesPromoAndIntroBeforeRegular() async throws {
        let h = try await ExecutorHarness.make(model: Self.model())
        let result = try await run(h, Self.spec(newPrice: "24.99", preserve: nil, start: h.today.adding(days: 9)))
        #expect(result.state == .scheduled)
        let writes = await Self.writes(h)
        let promo = try #require(writes.firstIndex { $0.method == "PATCH" && $0.path == "/v1/subscriptionPromotionalOffers/\(Self.promoId)" })
        for territory in Self.territories {
            let regular = try Self.index(writes, "POST", "/v1/subscriptionPrices", territory)
            let intro = try Self.index(writes, "POST", "/v1/subscriptionIntroductoryOffers", territory)
            #expect(intro < regular, "\(territory): \(writes)")
            #expect(promo < regular, "\(territory): \(writes)")
        }
        let offer = try #require(await h.fake.model.promos.first { $0.id == Self.promoId })
        #expect(offer.prices.allSatisfy { $0.pricePointId == "pp-sub-n-\($0.territory)-14" })
        try await noIntroOrPromoAtOrAboveRegular(h)
    }

    @Test func increaseWritesRegularBeforeIntroAndLeavesPromo() async throws {
        let h = try await ExecutorHarness.make(model: Self.model())
        let result = try await run(h, Self.spec(newPrice: "34.99", preserve: true, start: h.today.adding(days: 9)))
        #expect(result.state == .scheduled)
        let writes = await Self.writes(h)
        #expect(!writes.contains { $0.method == "PATCH" })
        for territory in Self.territories {
            let regular = try Self.index(writes, "POST", "/v1/subscriptionPrices", territory)
            let delete = try Self.index(writes, "DELETE", "/v1/subscriptionIntroductoryOffers/intro-sub-n-\(territory)", territory)
            let intro = try Self.index(writes, "POST", "/v1/subscriptionIntroductoryOffers", territory)
            #expect(regular < delete && delete < intro, "\(territory): \(writes)")
        }
        try await noIntroOrPromoAtOrAboveRegular(h)
    }

    @Test func decreaseIntroFailureSkipsRegularInThatTerritory() async throws {
        let h = try await ExecutorHarness.make(model: Self.model())
        await h.fake.inject(Self.injected, times: 1, matching: .pathPrefix("/v1/subscriptionIntroductoryOffers"))
        let result = try await run(h, Self.spec(newPrice: "24.99", preserve: nil, start: h.today.adding(days: 9)))
        #expect(result.state == .partiallyApplied)
        let writes = await Self.writes(h)
        #expect(!writes.contains { $0.path == "/v1/subscriptionPrices" && $0.territory == "CZE" })
        #expect(writes.contains { $0.path == "/v1/subscriptionPrices" && $0.territory == "DEU" })
        let items = try h.store.items(planId: result.planId)
        let czeRegular = try #require(items.first {
            $0.item.cell == .regular(subscriptionId: "sub-n", territory: "CZE", planType: .upfront) && $0.item.op == .post
        })
        #expect(czeRegular.state == .skipped)
        try await noIntroOrPromoAtOrAboveRegular(h)
    }

    @Test func decreasePromoFailureSkipsEveryRegularPrice() async throws {
        let h = try await ExecutorHarness.make(model: Self.model())
        // The only PATCH of this plan is the promo re-price; a path match would also hit the promo price read of the initial sync.
        await h.fake.inject(Self.injected, times: 1, matching: .method("PATCH"))
        let result = try await run(h, Self.spec(newPrice: "24.99", preserve: nil, start: h.today.adding(days: 9)))
        #expect(result.state == .partiallyApplied)
        let writes = await Self.writes(h)
        #expect(!writes.contains { $0.path == "/v1/subscriptionPrices" })
        let items = try h.store.items(planId: result.planId)
        for territory in Self.territories {
            let regular = try #require(items.first {
                $0.item.cell == .regular(subscriptionId: "sub-n", territory: territory, planType: .upfront) && $0.item.op == .post
            })
            #expect(regular.state == .skipped)
        }
        try await noIntroOrPromoAtOrAboveRegular(h)
    }

    @Test func increaseRegularFailureSkipsIntroStepsInThatTerritory() async throws {
        let h = try await ExecutorHarness.make(model: Self.model())
        await h.fake.inject(Self.injected, times: 1, matching: .pathPrefix("/v1/subscriptionPrices"))
        let result = try await run(h, Self.spec(newPrice: "34.99", preserve: true, start: h.today.adding(days: 9)))
        #expect(result.state == .partiallyApplied)
        let writes = await Self.writes(h)
        #expect(!writes.contains { $0.path.hasPrefix("/v1/subscriptionIntroductoryOffers") && $0.territory == "CZE" })
        #expect(writes.contains { $0.path == "/v1/subscriptionIntroductoryOffers" && $0.territory == "DEU" })
        try await noIntroOrPromoAtOrAboveRegular(h)
    }
}
