import Foundation
import Testing
import Domain
import Catalog
@testable import Policy
import PurserTestSupport

@Suite struct IntroRulesTests {
    let empty: CellState = .intro(current: nil, future: nil)

    @Test func i2() {
        let snapshot = basicCatalog().snapshot()
        let ok = ItemFactory.introPost(1, before: empty, sub: "s", territory: "USA", mode: .payAsYouGo, duration: .oneYear, price: d("23.99"), start: today.adding(days: 3))
        #expect(I2OfferShapeRule().evaluate(context(snapshot, [ok])).isEmpty)
        let bad = ItemFactory.introPost(1, before: empty, sub: "s", territory: "USA", mode: .payAsYouGo, duration: .oneMonth, periods: 3, price: d("2.99"), start: today.adding(days: 3))
        #expect(I2OfferShapeRule().evaluate(context(snapshot, [bad])).map(\.severity) == [.block(.cell)])
    }

    @Test func i4PlanUsesPostPlanRegularPrice() {
        var catalog = basicCatalog()
        catalog.addIntro("s", "USA", price: d("23.99"))
        let snapshot = catalog.snapshot()
        let mild = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("25.99"), start: today.adding(days: 7), preserve: false)
        #expect(I4IntroBelowRegularRule().evaluate(context(snapshot, [mild])).isEmpty)
        let deep = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("22.99"), start: today.adding(days: 7), preserve: false)
        let verdicts = I4IntroBelowRegularRule().evaluate(context(snapshot, [deep]))
        #expect(verdicts.map(\.severity) == [.block(.cell)])
        #expect(verdicts[0].cell == deep.cell)
        #expect(verdicts[0].message == "The intro 23.99 USD is not cheaper than the regular price 22.99 USD effective from \(today.adding(days: 7)).")
    }

    @Test func i4Invariant() {
        var catalog = basicCatalog()
        catalog.addIntro("s", "USA", price: d("23.99"))
        #expect(I4IntroBelowRegularRule().check(catalog.snapshot(), today: today).isEmpty)
        catalog.addIntro("s", "DEU", price: d("29.99"))
        let verdicts = I4IntroBelowRegularRule().check(catalog.snapshot(), today: today)
        #expect(verdicts.map(\.cell) == [.intro(subscriptionId: "s", territory: "DEU", planType: .upfront)])
        #expect(verdicts[0].message == "The intro 29.99 USD is not cheaper than the regular price 29.99 USD.")
    }

    @Test func i5PlanRule() {
        let snapshot = basicCatalog().snapshot()
        let ok = ItemFactory.introPost(1, before: empty, sub: "s", territory: "USA", price: d("23.99"), start: today.adding(days: 3))
        #expect(I5NominalDiscountRule().evaluate(context(snapshot, [ok], nominal: ["s": d("0.20")])).isEmpty)
        let shallow = ItemFactory.introPost(1, before: empty, sub: "s", territory: "USA", price: d("24.99"), start: today.adding(days: 3))
        #expect(I5NominalDiscountRule().evaluate(context(snapshot, [shallow], nominal: ["s": d("0.20")])).map(\.severity) == [.block(.cell)])
        let deep = ItemFactory.introPost(1, before: empty, sub: "s", territory: "USA", price: d("19.99"), start: today.adding(days: 3))
        let warn = I5NominalDiscountRule().evaluate(context(snapshot, [deep], nominal: ["s": d("0.20")]))
        #expect(warn.map(\.severity) == [.warn])
        #expect(warn[0].message.contains("33.3 %"))
    }

    @Test func i5Invariant() {
        var catalog = basicCatalog()
        catalog.addIntro("s", "USA", price: d("23.99"))
        #expect(I5NominalDiscountInvariant(nominalDiscounts: ["s": d("0.20")]).check(catalog.snapshot(), today: today).isEmpty)
        catalog.addIntro("s", "DEU", price: d("26.99"))
        let verdicts = I5NominalDiscountInvariant(nominalDiscounts: ["s": d("0.20")]).check(catalog.snapshot(), today: today)
        #expect(verdicts.map(\.cell) == [.intro(subscriptionId: "s", territory: "DEU", planType: .upfront)])
        #expect(I5NominalDiscountInvariant(nominalDiscounts: [:]).check(catalog.snapshot(), today: today).isEmpty)
    }

    @Test func i6() {
        var catalog = basicCatalog(state: .readyToSubmit)
        catalog.addIntro("s", "USA", price: d("23.99"))
        let snapshot = catalog.snapshot()
        let delete = ItemFactory.introDelete(1, snapshot, sub: "s", territory: "USA")
        let after = ItemFactory.introPost(2, before: delete.target, sub: "s", territory: "USA", price: d("22.99"), start: nil, dependsOn: [1])
        #expect(I6IntroSlotsRule().evaluate(context(snapshot, [delete, after])).isEmpty)
        let overlapping = ItemFactory.introPost(1, before: snapshot.cellState(.intro(subscriptionId: "s", territory: "USA", planType: .upfront), on: today),
                                                sub: "s", territory: "USA", price: d("22.99"), start: today.adding(days: 5))
        #expect(I6IntroSlotsRule().evaluate(context(snapshot, [overlapping])).map(\.severity) == [.block(.cell)])
    }

    func liveCatalog() -> CatalogSnapshot {
        var catalog = basicCatalog()
        catalog.addIntro("s", "USA", price: d("23.99"))
        catalog.addIntro("s", "DEU", price: d("23.99"))
        return catalog.snapshot()
    }

    func replacement(_ snapshot: CatalogSnapshot, _ territory: TerritoryCode, seq: Int, end: CalendarDate) -> [PlannedItem] {
        let endItem = ItemFactory.introEnd(seq, snapshot, sub: "s", territory: territory, at: end)
        let post = ItemFactory.introPost(seq + 1, before: endItem.target, sub: "s", territory: territory, price: d("22.99"), start: end, dependsOn: [seq])
        return [endItem, post]
    }

    @Test func i7DeleteOfLiveIntroBlocks() {
        let snapshot = liveCatalog()
        let delete = ItemFactory.introDelete(1, snapshot, sub: "s", territory: "USA")
        #expect(I7LiveIntroRule().evaluate(context(snapshot, [delete])).map(\.severity) == [.block(.plan)])
    }

    @Test func i7ReplacementNeedsCanaryUntilS4b() {
        let snapshot = liveCatalog()
        let items = replacement(snapshot, "USA", seq: 1, end: today.adding(days: 3))
        #expect(I7LiveIntroRule(liveReplaceConfirmed: true).evaluate(context(snapshot, items)).isEmpty)
        #expect(I7LiveIntroRule(liveReplaceConfirmed: false).evaluate(context(snapshot, items)).map(\.severity) == [.block(.plan)])
        let canary = I7LiveIntroRule(liveReplaceConfirmed: false).evaluate(context(snapshot, items, canary: true))
        #expect(canary.map(\.riskClass) == ["I7 canary of a live intro replacement"])
    }

    @Test func i7CanaryAllowsOneTerritoryPerProductAndLeadTime() {
        let snapshot = liveCatalog()
        let two = replacement(snapshot, "USA", seq: 1, end: today.adding(days: 3)) + replacement(snapshot, "DEU", seq: 3, end: today.adding(days: 3))
        #expect(I7LiveIntroRule(liveReplaceConfirmed: true).evaluate(context(snapshot, two, canary: true)).map(\.severity) == [.block(.plan)])
        let early = replacement(snapshot, "USA", seq: 1, end: today.adding(days: 1))
        #expect(I7LiveIntroRule(liveReplaceConfirmed: true).evaluate(context(snapshot, early)).map(\.severity) == [.block(.plan)])
    }

    /// Spec I7: an Effective CANARY plan unlocks the remaining territories of its product, and only of that product.
    @Test func i7EffectiveCanaryUnlocksOnlyItsProduct() {
        var catalog = basicCatalog()
        catalog.addSubscription("k", prices: ["USA": d("29.99"), "DEU": d("29.99")])
        for sub in ["s", "k"] {
            catalog.addIntro(sub, "USA", price: d("23.99"))
            catalog.addIntro(sub, "DEU", price: d("23.99"))
        }
        let snapshot = catalog.snapshot()
        let end = today.adding(days: 3)
        func swap(_ sub: String, _ territory: TerritoryCode, seq: Int) -> [PlannedItem] {
            let endItem = ItemFactory.introEnd(seq, snapshot, sub: sub, territory: territory, at: end)
            let post = ItemFactory.introPost(seq + 1, before: endItem.target, sub: sub, territory: territory, price: d("22.99"),
                                             start: end, dependsOn: [seq])
            return [endItem, post]
        }
        let rule = I7LiveIntroRule(liveReplaceConfirmed: false)
        let productS = swap("s", "USA", seq: 1) + swap("s", "DEU", seq: 3)
        // Without an Effective canary the replacement is blocked.
        #expect(rule.evaluate(context(snapshot, productS)).map(\.severity) == [.block(.plan)])
        // With an Effective canary of "s" neither a block nor the one-territory limit applies to "s".
        #expect(rule.evaluate(context(snapshot, productS, unlocked: ["s"])).isEmpty)
        // Another product in the same plan stays blocked.
        let withK = productS + swap("k", "USA", seq: 5)
        let blocked = rule.evaluate(context(snapshot, withK, unlocked: ["s"]))
        #expect(blocked.map(\.severity) == [.block(.plan)])
        #expect(blocked[0].message == "Replacing a live intro (1 cells) waits for spike S4b; for now only a CANARY plan or a product with an Effective canary may run.")
        // In a CANARY plan only the locked product needs C2 and counts against the one-territory limit.
        let canary = rule.evaluate(context(snapshot, withK, canary: true, unlocked: ["s"]))
        #expect(canary.map(\.severity) == [.confirm(.c2)])
        #expect(canary.map(\.cell) == [.intro(subscriptionId: "k", territory: "USA", planType: .upfront)])
    }

    @Test func i8() {
        var catalog = basicCatalog(state: .readyToSubmit)
        catalog.addIntro("s", "USA", price: d("23.99"))
        let snapshot = catalog.snapshot()
        let start = today.adding(days: 7)
        let price = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: start, preserve: true)
        let introCell: CellKey = .intro(subscriptionId: "s", territory: "USA", planType: .upfront)
        #expect(I8IntroReplacementRule().evaluate(context(snapshot, [price])).map(\.severity) == [.block(.cell)])
        let delete = ItemFactory.introDelete(2, snapshot, sub: "s", territory: "USA")
        let post = ItemFactory.introPost(3, before: delete.target, sub: "s", territory: "USA", price: d("27.99"), start: start, dependsOn: [2])
        #expect(I8IntroReplacementRule().evaluate(context(snapshot, [price, delete, post])).isEmpty)
        let skipped = I8IntroReplacementRule().evaluate(context(snapshot, [price], skipped: [introCell: "the intro ends, we will not renew it"]))
        #expect(skipped.map(\.severity) == [.confirm(.c2)])
        let noIntro = basicCatalog().snapshot()
        #expect(I8IntroReplacementRule().evaluate(context(noIntro, [ItemFactory.regularPost(1, noIntro, sub: "s", territory: "USA", price: d("34.99"), start: start, preserve: true)])).isEmpty)
    }

    @Test func i8FutureIntroIsReplacedFromItsOwnStart() {
        var catalog = basicCatalog(state: .readyToSubmit)
        let introStart = today.adding(days: 30)
        catalog.addIntro("s", "USA", price: d("23.99"), start: introStart, ascId: "io-later")
        let snapshot = catalog.snapshot()
        let price = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 7), preserve: true)
        let introState = snapshot.cellState(.intro(subscriptionId: "s", territory: "USA", planType: .upfront), on: today)
        let wrongDay = ItemFactory.introPost(2, before: introState, sub: "s", territory: "USA", price: d("27.99"), start: today.adding(days: 7))
        #expect(I8IntroReplacementRule().evaluate(context(snapshot, [price, wrongDay])).map(\.severity) == [.block(.cell)])
        let ownStart = ItemFactory.introPost(2, before: introState, sub: "s", territory: "USA", price: d("27.99"), start: introStart)
        #expect(I8IntroReplacementRule().evaluate(context(snapshot, [price, ownStart])).isEmpty)
    }

    /// Resume: the replacement is already in the snapshot and no longer to be written; the plan still contains it.
    @Test func i8CountsAReplacementTheResumeAlreadyWrote() {
        var catalog = basicCatalog(state: .readyToSubmit)
        let start = today.adding(days: 7)
        catalog.addIntro("s", "USA", price: d("23.99"), start: start, ascId: "io-written")
        let snapshot = catalog.snapshot()
        let price = ItemFactory.regularPost(3, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: start, preserve: true)
        #expect(I8IntroReplacementRule().evaluate(context(snapshot, [price])).map(\.severity) == [.block(.cell)])
        let post = ItemFactory.introPost(2, before: empty, sub: "s", territory: "USA", price: d("23.99"), start: start)
        #expect(I8IntroReplacementRule().evaluate(context(snapshot, [price], written: [post])).isEmpty)
    }

    @Test func i9() {
        let snapshot = basicCatalog().snapshot()
        #expect(I9IntroEligibilityRule().evaluate(context(snapshot, [])).isEmpty)
        var catalog = basicCatalog()
        catalog.addSubscription("k", prices: ["KOR": d("29.99")])
        let korea = ItemFactory.introPost(1, before: empty, sub: "k", territory: "KOR", price: d("23.99"), start: today.adding(days: 3))
        let verdicts = I9IntroEligibilityRule().evaluate(context(catalog.snapshot(), [korea]))
        #expect(verdicts.map(\.severity) == [.warn, .warn])
        #expect(verdicts[1].cell == korea.cell)
    }
}
