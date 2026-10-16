import Foundation
import Testing
import Domain
import Catalog
@testable import Policy
import PurserTestSupport

@Suite struct RegularPriceRulesTests {
    let snapshot = basicCatalog().snapshot()

    @Test func r2() {
        let upfront = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 7), preserve: true)
        #expect(R2MonthlyWriteRule().evaluate(context(snapshot, [upfront])).isEmpty)
        let monthly = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("3.99"), start: today.adding(days: 7), preserve: true, planType: .monthly)
        #expect(R2MonthlyWriteRule().evaluate(context(snapshot, [monthly])).map(\.severity) == [.block(.plan)])
    }

    @Test func r4() {
        let ok = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 2), preserve: true)
        #expect(R4LeadTimeRule().evaluate(context(snapshot, [ok])).isEmpty)
        let tooSoon = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 1), preserve: true)
        let null = ItemFactory.regularPost(2, snapshot, sub: "s", territory: "DEU", price: d("34.99"), start: nil, preserve: true)
        let intro = ItemFactory.introPost(3, before: .intro(current: nil, future: nil), sub: "s", territory: "CZE", price: d("23.99"), start: nil)
        let verdicts = R4LeadTimeRule().evaluate(context(snapshot, [tooSoon, null, intro]))
        #expect(verdicts.map(\.severity) == [.block(.cell), .block(.cell), .block(.cell)])
        #expect(verdicts[1].message.contains("without a startDate"))
    }

    @Test func r4AllowsImmediateIntroOnUnsubmittedProduct() {
        let unsubmitted = basicCatalog(state: .readyToSubmit).snapshot()
        let intro = ItemFactory.introPost(1, before: .intro(current: nil, future: nil), sub: "s", territory: "CZE", price: d("23.99"), start: nil)
        #expect(R4LeadTimeRule().evaluate(context(unsubmitted, [intro])).isEmpty)
    }

    func catalogWithScheduled(start: CalendarDate) -> CatalogSnapshot {
        var catalog = basicCatalog()
        catalog.setRegular("s", "USA", d("31.99"), start: start, ascId: "rp-scheduled")
        return catalog.snapshot()
    }

    @Test func r5() {
        let plain = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 7), preserve: true)
        #expect(R5ReplacementRule().evaluate(context(snapshot, [plain])).isEmpty)
        let scheduled = catalogWithScheduled(start: today.adding(days: 20))
        let delete = ItemFactory.regularDelete(1, scheduled, sub: "s", territory: "USA")
        let replace = ItemFactory.regularPost(2, scheduled, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 7), preserve: true, afterDelete: true, dependsOn: [1])
        let verdicts = R5ReplacementRule().evaluate(context(scheduled, [delete, replace]))
        #expect(verdicts.map(\.severity) == [.confirm(.c2)])
        #expect(verdicts[0].message.contains("Replaces the change from \(today.adding(days: 20).iso)"))
        #expect(verdicts[0].riskClass == "R5 scheduled change replaced")
    }

    @Test func r6() {
        let farEnough = catalogWithScheduled(start: today.adding(days: 3))
        #expect(R6CutoffRule().evaluate(context(farEnough, [ItemFactory.regularDelete(1, farEnough, sub: "s", territory: "USA")])).isEmpty)
        let tooClose = catalogWithScheduled(start: today.adding(days: 2))
        #expect(R6CutoffRule().evaluate(context(tooClose, [ItemFactory.regularDelete(1, tooClose, sub: "s", territory: "USA")])).map(\.severity) == [.block(.cell)])
    }

    @Test func r7() {
        let increase = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 7), preserve: true)
        #expect(R7DecreaseRule().evaluate(context(snapshot, [increase])).isEmpty)
        let decrease = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("24.99"), start: today.adding(days: 7), preserve: false)
        let verdicts = R7DecreaseRule().evaluate(context(snapshot, [decrease]))
        #expect(verdicts.map(\.riskClass) == ["R7 regular price decrease"])
    }

    @Test func r8() {
        let preserved = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 7), preserve: true)
        #expect(R8IncreaseWithoutPreserveRule().evaluate(context(snapshot, [preserved])).isEmpty)
        let notPreserved = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("34.99"), start: today.adding(days: 7), preserve: false)
        #expect(R8IncreaseWithoutPreserveRule().evaluate(context(snapshot, [notPreserved])).map(\.severity) == [.confirm(.c2)])
    }

    @Test func r9() {
        let small = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("31.99"), start: today.adding(days: 7), preserve: false)
        #expect(R9ConsentRule().evaluate(context(snapshot, [small])).isEmpty)
        let preservedBig = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "DEU", price: d("59.99"), start: today.adding(days: 7), preserve: true)
        #expect(R9ConsentRule().evaluate(context(snapshot, [preservedBig])).isEmpty)
        let germany = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "DEU", price: d("59.99"), start: today.adding(days: 7), preserve: false)
        let verdicts = R9ConsentRule().evaluate(context(snapshot, [germany]))
        #expect(verdicts.map(\.severity) == [.warn])
        #expect(verdicts[0].message.contains("CERTAIN (DEU)"))
        #expect(verdicts[0].message.contains("POSSIBLE (+100.0%)"))
    }

    @Test func r9StackedIncrease() {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: [:], available: ["USA"])
        catalog.setRegular("s", "USA", d("19.99"), start: CalendarDate(year: 2025, month: 1, day: 1))
        catalog.setRegular("s", "USA", d("24.99"), start: CalendarDate(year: 2026, month: 3, day: 1))
        let snapshot = catalog.snapshot()
        let item = ItemFactory.regularPost(1, snapshot, sub: "s", territory: "USA", price: d("26.99"), start: today.adding(days: 7), preserve: false)
        #expect(R9ConsentRule().evaluate(context(snapshot, [item])).first?.message.contains("CUMULATIVE") == true)
    }
}
