import Foundation
import Testing
import Domain
import Catalog
import Planner
import Executor
import MCPBridge
@testable import MCPTools
import PurserTestSupport

private func d(_ text: String) -> Decimal { Decimal(string: text)! }

private func catalog() -> CatalogSnapshot {
    var catalog = SyntheticCatalog()
    catalog.addSubscription("s", prices: ["USA": d("29.99"), "DEU": d("29.99"), "CZE": d("29.99")])
    catalog.addPromo("s", code: "winback", prices: ["USA": d("19.99")])
    catalog.addIAP("life", base: "USA", manual: ["USA": d("49.99")])
    return catalog.snapshot()
}

private func message(_ body: () throws -> Void) -> String? {
    do { try body() } catch let error as ToolArgumentError { return error.message } catch { return "other: \(error)" }
    return nil
}

@Suite struct PlanArgumentsTests {
    @Test func regularPlanResolvesProductIdsAndKeepsAmountsExact() throws {
        let arguments: JSONValue = ["subscription_ids": ["com.example.s"],
                                    "prices": [["territory": "usa", "amount": .number(34.99)], ["territory": "DEU", "amount": "39.99"]],
                                    "start_date": "2026-11-01", "preserve_current_price": true, "territories": ["USA"], "reason": " raise "]
        let parsed = PlanArguments(arguments, snapshot: catalog())
        guard case let .regular(spec) = try parsed.regular() else { Issue.record("not a regular spec"); return }
        #expect(spec.subscriptionIds == ["s"])
        #expect(spec.planType == .upfront)
        #expect(Set(spec.prices) == [TerritoryAmount(territory: "USA", amount: d("34.99")), TerritoryAmount(territory: "DEU", amount: d("39.99"))])
        #expect(spec.startDate == CalendarDate(year: 2026, month: 11, day: 1))
        #expect(spec.preserveCurrentPrice == true)
        #expect(spec.filter.territories == ["USA"])
        #expect(parsed.reason == "raise")
    }

    @Test func regularPlanLeavesThePreserveChoiceOpenWhenItIsNotGiven() throws {
        let arguments: JSONValue = ["subscription_ids": ["s"], "prices": [["territory": "USA", "amount": .number(34.99)]]]
        guard case let .regular(spec) = try PlanArguments(arguments, snapshot: catalog()).regular() else { Issue.record("spec"); return }
        // The Planner blocks an increase without the choice (R1); the tool must not pick one for the caller.
        #expect(spec.preserveCurrentPrice == nil)
        #expect(spec.startDate == nil)
        #expect(spec.filter.territories == nil)
    }

    @Test func wrongArgumentsAreNamed() {
        let snapshot = catalog()
        #expect(message { _ = try PlanArguments(["subscription_ids": ["nope"], "prices": [["territory": "USA", "amount": 1]]], snapshot: snapshot).regular() }?
            .contains("No subscription") == true)
        #expect(message { _ = try PlanArguments(["subscription_ids": ["s"], "prices": [["territory": "XXX", "amount": 1]]], snapshot: snapshot).regular() }?
            .contains("Unknown territory") == true)
        #expect(message { _ = try PlanArguments(["subscription_ids": ["s"], "prices": [["territory": "USA", "amount": "9.99abc"]]], snapshot: snapshot).regular() }?
            .contains("territory and an amount") == true)
        #expect(message { _ = try PlanArguments(["subscription_ids": ["s"], "prices": [["territory": "USA", "amount": 1], ["territory": "usa", "amount": 2]]],
                                                snapshot: snapshot).regular() }?.contains("more than once") == true)
        #expect(message { _ = try PlanArguments(["subscription_ids": ["s"], "prices": [["territory": "USA", "amount": 1]], "start_date": "1.11.2026"],
                                                snapshot: snapshot).regular() }?.contains("YYYY-MM-DD") == true)
        #expect(message { _ = try PlanArguments(["subscription_ids": ["s"]], snapshot: snapshot).regular() }?.contains("prices") == true)
    }

    @Test func iapPlanTakesBaseTerritoryAndPrices() throws {
        let arguments: JSONValue = ["iap": "com.example.life", "base_territory": "USA", "prices": [["territory": "USA", "amount": .number(59.99)]]]
        guard case let .iap(spec) = try PlanArguments(arguments, snapshot: catalog()).iap() else { Issue.record("spec"); return }
        #expect(spec == IAPPlanSpec(iapId: "life", baseTerritory: "USA", prices: [TerritoryAmount(territory: "USA", amount: d("59.99"))], startDate: nil))
    }

    @Test func introOfferPricing() throws {
        let snapshot = catalog()
        let base: [String: JSONValue] = ["subscription_ids": ["s"], "duration": "ONE_WEEK", "number_of_periods": 1]
        guard case let .intro(trial) = try PlanArguments(.object(base.merging(["mode": "FREE_TRIAL"]) { $1 }), snapshot: snapshot).intro() else {
            Issue.record("spec"); return
        }
        #expect(trial.pricing == .freeTrial)
        #expect(trial.duration == .oneWeek)
        #expect(!trial.canary)

        let paid = base.merging(["mode": "PAY_UP_FRONT", "percent_of_regular": 80, "nominal_discount": 20, "end_date": "2026-12-31"]) { $1 }
        guard case let .intro(percent) = try PlanArguments(.object(paid), snapshot: snapshot).intro() else { Issue.record("spec"); return }
        #expect(percent.pricing == .percentOfRegular(d("0.8")))
        #expect(percent.nominalDiscount == d("0.2"))
        #expect(percent.endDate == CalendarDate(year: 2026, month: 12, day: 31))

        #expect(message { _ = try PlanArguments(.object(base.merging(["mode": "FREE_TRIAL", "percent_of_regular": 50]) { $1 }), snapshot: snapshot).intro() }?
            .contains("FREE_TRIAL") == true)
        #expect(message { _ = try PlanArguments(.object(base.merging(["mode": "PAY_UP_FRONT"]) { $1 }), snapshot: snapshot).intro() }?
            .contains("needs percent_of_regular or prices") == true)
        #expect(message { _ = try PlanArguments(.object(base.merging(["mode": "HALF_PRICE"]) { $1 }), snapshot: snapshot).intro() }?
            .contains("FREE_TRIAL, PAY_UP_FRONT, PAY_AS_YOU_GO") == true)
        #expect(message { _ = try PlanArguments(.object(base.merging(["mode": "PAY_UP_FRONT", "percent_of_regular": 120]) { $1 }), snapshot: snapshot).intro() }?
            .contains("between 0 and 100") == true)
    }

    @Test func promoActions() throws {
        let snapshot = catalog()
        let create: JSONValue = ["action": "create", "subscription": "s", "offer_code": "spring", "name": "Spring", "mode": "PAY_AS_YOU_GO",
                                 "duration": "ONE_MONTH", "number_of_periods": 3, "prices": [["territory": "USA", "amount": .number(9.99)]]]
        #expect(try PlanArguments(create, snapshot: snapshot).promo() == .promo(PromoPlanSpec(action: .create(
            subscriptionId: "s", offerCode: "spring", name: "Spring", mode: .payAsYouGo, duration: .oneMonth, numberOfPeriods: 3,
            pricing: .table([TerritoryAmount(territory: "USA", amount: d("9.99"))])))))
        #expect(try PlanArguments(["action": "reprice", "offer_id": "po-winback", "percent_of_regular": 50], snapshot: snapshot).promo()
            == .promo(PromoPlanSpec(action: .reprice(offerAscId: "po-winback", pricing: .percentOfRegular(d("0.5"))))))
        // Deleting without the explicit confirmation stays unconfirmed; the Planner decides what that means.
        #expect(try PlanArguments(["action": "delete", "offer_id": "po-winback"], snapshot: snapshot).promo()
            == .promo(PromoPlanSpec(action: .delete(offerAscId: "po-winback", confirmedUnusedByApp: false))))
        #expect(message { _ = try PlanArguments(["action": "reprice", "offer_id": "missing", "percent_of_regular": 50], snapshot: snapshot).promo() }?
            .contains("No promotional offer") == true)
        #expect(message { _ = try PlanArguments(["action": "rename"], snapshot: snapshot).promo() }?.contains("create, reprice or delete") == true)
    }

    @Test func productCreationRequest() throws {
        let arguments: JSONValue = ["group_name": " Premium ", "subscriptions": [["product_id": "premium_yearly", "name": "Premium yearly", "period": "ONE_YEAR"]],
                                    "non_consumables": [["product_id": "lifetime", "name": "Lifetime"]]]
        #expect(try PlanArguments.productCreation(arguments) == ProductCreationRequest(
            groupName: "Premium", subscriptions: [NewSubscriptionProduct(productId: "premium_yearly", name: "Premium yearly", period: .oneYear)],
            nonConsumables: [NewNonConsumableProduct(productId: "lifetime", name: "Lifetime")]))
        #expect(message { _ = try PlanArguments.productCreation(["subscriptions": [["product_id": "a", "name": "A", "period": "FORTNIGHT"]]]) }?
            .contains("period must be one of") == true)
        #expect(try PlanArguments.productCreation([:]) == ProductCreationRequest(groupName: nil, subscriptions: [], nonConsumables: []))
    }
}
