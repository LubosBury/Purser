import Foundation
import Testing
import Domain
import Catalog
import Policy
import Planner
import Store
import MCPBridge
@testable import MCPTools
import PurserTestSupport

private func d(_ text: String) -> Decimal { Decimal(string: text)! }

@Suite struct RenderingTests {
    private func catalog() -> SyntheticCatalog {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": d("29.99"), "DEU": d("24.99")])
        catalog.setRegular("s", "USA", d("34.99"), start: SyntheticCatalog.today.adding(days: 10))
        catalog.addIntro("s", "USA", mode: .freeTrial, duration: .oneWeek, price: nil)
        catalog.addPromo("s", code: "winback", prices: ["USA": d("19.99")])
        catalog.addIAP("life", base: "USA", manual: ["USA": d("49.99")])
        return catalog
    }

    @Test func productsListSubscriptionsAndIAPs() {
        let products = MCPRender.products(catalog().snapshot())
        #expect(products["subscriptions"]?.arrayValue?.first?["product_id"] == "com.example.s")
        #expect(products["subscriptions"]?.arrayValue?.first?["group"] == "Synthetic group")
        #expect(products["in_app_purchases"]?.arrayValue?.first?["asc_id"] == "life")
    }

    @Test func subscriptionPricesShowCurrentScheduledIntroAndPromo() throws {
        let snapshot = catalog().snapshot()
        let prices = try #require(MCPRender.prices(productAscId: "s", snapshot: snapshot, territories: nil, today: SyntheticCatalog.today))
        let rows = try #require(prices["prices"]?.arrayValue)
        #expect(rows.map { $0["territory"] } == ["DEU", "USA"])
        let usa = rows[1]
        #expect(usa["price"] == .number(29.99))
        #expect(usa["scheduled_price"] == .number(34.99))
        #expect(usa["scheduled_from"] == .string(SyntheticCatalog.today.adding(days: 10).iso))
        #expect(usa["intro_offer"]?["mode"] == "FREE_TRIAL")
        #expect(rows[0]["scheduled_price"] == nil)
        #expect(prices["promotional_offers"]?.arrayValue?.first?["offer_id"] == "po-winback")

        let filtered = try #require(MCPRender.prices(productAscId: "s", snapshot: snapshot, territories: ["DEU"], today: SyntheticCatalog.today))
        #expect(filtered["prices"]?.arrayValue?.count == 1)
        #expect(MCPRender.prices(productAscId: "missing", snapshot: snapshot, territories: nil, today: SyntheticCatalog.today) == nil)
    }

    @Test func iapPricesShowTheManualSchedule() throws {
        let prices = try #require(MCPRender.prices(productAscId: "life", snapshot: catalog().snapshot(), territories: nil, today: SyntheticCatalog.today))
        #expect(prices["kind"] == "in_app_purchase")
        #expect(prices["base_territory"] == "USA")
        #expect(prices["manual_prices"]?.arrayValue?.first?["price"] == .number(49.99))
    }

    @Test func confirmationNeededGrowsWithTheLevel() {
        let risk = Verdict(rule: "R7", severity: .confirm(.c2), cell: .regular(subscriptionId: "s", territory: "USA", planType: .upfront),
                           message: "decrease", riskClass: "R7 regular price decrease")
        #expect(MCPRender.confirmationNeeded(level: .c0, excluded: 0, verdicts: [], appName: "Fruit Jar") == ["level": "C0"])
        #expect(MCPRender.confirmationNeeded(level: .c1, excluded: 2, verdicts: [], appName: "Fruit Jar")
            == ["level": "C1", "acknowledge_exclusions": true, "typed_app_name": "Fruit Jar"])
        let c2 = MCPRender.confirmationNeeded(level: .c2, excluded: 0, verdicts: [risk, risk], appName: "Fruit Jar")
        #expect(c2["checked_risk_classes"] == ["R7 regular price decrease"])
        #expect(c2["typed_app_name"] == "Fruit Jar")
        #expect(c2["reason"]?.stringValue?.contains("\(AppleConstants.c2MinReasonLength)") == true)
    }

    @Test func planShowsRowsVerdictsAndWhatApplyNeeds() throws {
        let snapshot = catalog().snapshot()
        let config = SyntheticCatalog.config(isProduction: true)
        let spec = PlanSpec.regular(RegularPlanSpec(subscriptionIds: ["s"], planType: .upfront,
                                                    prices: [TerritoryAmount(territory: "DEU", amount: d("19.99"))],
                                                    startDate: nil, preserveCurrentPrice: nil, skipIntroReplacement: [:], filter: PlanFilter()))
        let draft = try Planner(policy: PolicyEngine()).plan(spec, context: PlanningContext(snapshot: snapshot, config: config, today: SyntheticCatalog.today))
        #expect(draft.confirmationLevel == .c2)
        let rows = PlanDiff.rows(items: draft.items, verdicts: draft.verdicts, spec: spec, snapshot: snapshot, config: config, today: SyntheticCatalog.today)
        let stored = StoredPlan(id: "p1", origin: .regular, specJSON: "{}", importJSON: nil, binding: PlanBinding(config: config),
                                baseSyncId: draft.baseSyncId, state: .draft, pauseReason: nil, endReason: nil, planHash: draft.planHash,
                                verdictHash: draft.verdictHash, verdicts: draft.verdicts, excluded: draft.excluded, productStates: [:],
                                reason: nil, confirmationLevel: draft.confirmationLevel, appBuild: "test", estimateRequests: draft.estimate.requests,
                                estimateMinutes: draft.estimate.minutes, replanOf: nil, createdAt: Date(timeIntervalSince1970: 0),
                                updatedAt: Date(timeIntervalSince1970: 0), heartbeatAt: nil)
        let items = draft.items.map { StoredItem(planId: "p1", item: $0, state: .pending, attempts: 0, ascId: nil, errorJSON: nil,
                                                 verifiedAt: nil, effectiveAt: nil, supersededBy: nil) }
        let rendered = MCPRender.plan(stored, items: items, rows: rows, appName: config.name, productName: { "Name of \($0)" },
                                      flaggedOnly: false, maxRows: 200)
        #expect(rendered["plan_id"] == "p1")
        #expect(rendered["state"] == "draft")
        #expect(rendered["blocked"] == false)
        #expect(rendered["confirmation_needed"]?["level"] == "C2")
        #expect(rendered["confirmation_needed"]?["typed_app_name"] == .string(config.name))
        #expect(rendered["confirmation_needed"]?["checked_risk_classes"]?.arrayValue?.isEmpty == false)
        #expect(rendered["rows_total"] == .number(Double(rows.count)))
        let row = try #require(rendered["rows"]?.arrayValue?.first)
        #expect(row["product"] == "Name of s")
        #expect(row["territory"] == "DEU")
        #expect(row["state"] == "pending")
        #expect(rendered["item_states"]?["pending"] == .number(Double(items.count)))

        let capped = MCPRender.plan(stored, items: items, rows: rows, appName: config.name, productName: { $0 }, flaggedOnly: false, maxRows: 0)
        #expect(capped["rows"]?.arrayValue?.isEmpty == true)
        #expect(capped["rows_total"] == .number(Double(rows.count)))
    }
}
