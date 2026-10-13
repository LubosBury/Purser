import Foundation
import Testing
import Domain
import Catalog
@testable import Planner
import PurserTestSupport

@Suite struct SnapperTests {
    let cell: CellKey = .regular(subscriptionId: "s", territory: "USA", planType: .upfront)

    func snapper(_ prices: [String], planType: PlanType? = .upfront) -> Snapper {
        Snapper(index: PricePointIndex(prices.map {
            PricePoint(id: "p\($0)", productAscId: "s", territory: "USA", planType: planType, customerPrice: d($0), proceeds: nil)
        }))
    }

    func point(_ outcome: SnapOutcome) -> Decimal? {
        if case let .snapped(result) = outcome { return result.point.customerPrice }
        return nil
    }

    @Test func regularSnapsToNearestAndTiesGoDown() {
        let s = snapper(["9.99", "10.99", "11.99"])
        #expect(point(s.snap(d("10.70"), productAscId: "s", territory: "USA", planType: .upfront, direction: .nearest, cell: cell)) == d("10.99"))
        #expect(point(s.snap(d("10.49"), productAscId: "s", territory: "USA", planType: .upfront, direction: .nearest, cell: cell)) == d("9.99"))
    }

    @Test func discountsSnapDown() {
        let s = snapper(["9.99", "10.99", "11.99"])
        #expect(point(s.snap(d("10.98"), productAscId: "s", territory: "USA", planType: .upfront, direction: .down, cell: cell)) == d("9.99"))
        #expect(point(s.snap(d("10.99"), productAscId: "s", territory: "USA", planType: .upfront, direction: .down, cell: cell)) == d("10.99"))
    }

    @Test func deviationIsRelativeToTheAmount() {
        #expect(Snapper.deviation(of: d("9.99"), from: d("10.99")) == d("1") / d("10.99"))
        #expect(Snapper.deviation(of: d("10"), from: d("10")) == 0)
    }

    @Test func warnAboveTwoPercentBlockAboveTenPercent() {
        let s = snapper(["9.99", "10.99"])
        guard case let .snapped(ok) = s.snap(d("10.99"), productAscId: "s", territory: "USA", planType: .upfront, direction: .down, cell: cell) else { Issue.record("blocked"); return }
        #expect(ok.warning == nil && ok.deviation == 0)
        guard case let .snapped(warned) = s.snap(d("10.50"), productAscId: "s", territory: "USA", planType: .upfront, direction: .down, cell: cell) else { Issue.record("blocked"); return }
        #expect(warned.warning?.severity == .warn)
        #expect(warned.warning?.rule == "S4")
        guard case let .blocked(verdict) = s.snap(d("12.50"), productAscId: "s", territory: "USA", planType: .upfront, direction: .down, cell: cell) else { Issue.record("not blocked"); return }
        #expect(verdict.severity == .block(.cell))
        #expect(verdict.cell == cell)
    }

    @Test func missingPointBlocks() {
        let s = snapper(["9.99"])
        guard case let .blocked(below) = s.snap(d("5"), productAscId: "s", territory: "USA", planType: .upfront, direction: .down, cell: cell) else { Issue.record("not blocked"); return }
        #expect(below.message.contains("≤ 5"))
        guard case .blocked = s.snap(d("5"), productAscId: "s", territory: "DEU", planType: .upfront, direction: .nearest, cell: cell) else { Issue.record("not blocked"); return }
        guard case .blocked = s.snap(d("0"), productAscId: "s", territory: "USA", planType: .upfront, direction: .nearest, cell: cell) else { Issue.record("not blocked"); return }
    }

    @Test func pointsWithoutPlanTypeAreUsedAsFallback() {
        let s = snapper(["9.99"], planType: nil)
        #expect(point(s.snap(d("9.99"), productAscId: "s", territory: "USA", planType: .upfront, direction: .nearest, cell: cell)) == d("9.99"))
    }
}
