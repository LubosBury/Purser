import Foundation
import Testing
import Domain
import Catalog
import ASCClient
@testable import Policy
import PurserTestSupport

@Suite struct AccessRulesTests {
    let snapshot = basicCatalog().snapshot()
    var post: PlannedItem { ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 7), preserve: true) }

    @Test func a2() {
        #expect(A2ProductionRule().evaluate(context(snapshot, [post])).isEmpty)
        let verdicts = A2ProductionRule().evaluate(context(snapshot, [post], config: SyntheticCatalog.config(isProduction: true)))
        #expect(verdicts.map(\.severity) == [.confirm(.c1)])
    }

    @Test func a3() {
        #expect(A3SingleApplyingRule().evaluate(context(snapshot, [post])).isEmpty)
        #expect(A3SingleApplyingRule().evaluate(context(snapshot, [post], others: ["plan-9"])).map(\.severity) == [.block(.plan)])
    }

    @Test func a4() {
        #expect(A4FreshBaseRule().evaluate(context(snapshot, [post])).isEmpty)
        var newer = basicCatalog()
        newer.setRegular("s", "USA", d("31.99"), start: today.adding(days: -1))
        let verdicts = A4FreshBaseRule().evaluate(context(newer.snapshot(), [post]))
        #expect(verdicts.map(\.severity) == [.block(.plan)])
        #expect(verdicts[0].message.contains("R|s|USA|UPFRONT"))
    }

    @Test func a5() {
        #expect(A5ProductStateRule().evaluate(context(snapshot, [post])).isEmpty)
        let inReview = basicCatalog(state: .waitingForReview).snapshot()
        let item = ItemFactory.regularPost(1, inReview, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 7), preserve: true)
        #expect(A5ProductStateRule().evaluate(context(inReview, [item])).map(\.severity) == [.block(.plan)])
    }

    @Test func a6() {
        #expect(A6AvailabilityRule().evaluate(context(snapshot, [post])).isEmpty)
        var catalog = basicCatalog()
        catalog.subscriptions["s"]?.availableTerritories = ["DEU", "CZE"]
        let verdicts = A6AvailabilityRule().evaluate(context(catalog.snapshot(), [post]))
        #expect(verdicts.map(\.severity) == [.block(.cell)])
        #expect(verdicts[0].cell == post.cell)
    }

    @Test func a6Invariant() {
        var catalog = basicCatalog()
        catalog.addIntro("s", "USA", price: d("23.99"))
        #expect(A6AvailabilityInvariant().check(catalog.snapshot(), today: today).isEmpty)
        catalog.subscriptions["s"]?.availableTerritories = ["DEU", "CZE"]
        let verdicts = A6AvailabilityInvariant().check(catalog.snapshot(), today: today)
        #expect(verdicts.map(\.cell) == [.intro(subscriptionId: "s", territory: "USA", planType: .upfront)])
    }

    @Test func a7() {
        let plenty = RateLimitSnapshot.parse("user-hour-lim:3500;user-hour-rem:3000;", at: Date())
        let scarce = RateLimitSnapshot.parse("user-hour-lim:3500;user-hour-rem:4;", at: Date())
        #expect(A7BudgetRule().evaluate(context(snapshot, [post], rateLimit: plenty)).isEmpty)
        #expect(A7BudgetRule().evaluate(context(snapshot, [post], rateLimit: nil)).isEmpty)
        #expect(A7BudgetRule().evaluate(context(snapshot, [post], rateLimit: scarce)).map(\.severity) == [.warn])
    }
}
