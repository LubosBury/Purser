import Testing
import Domain
import Planner

@Suite struct PromoCoverageTests {
    let available: Set<TerritoryCode> = ["USA", "CZE", "DEU", "JPN"]

    @Test func fullCoverageIsComplete() {
        let prices = available.map { NewPromoPrice(territory: $0, pricePointId: "pp-\($0)") }
        let coverage = PromoCoverage(prices: prices, available: available, mode: .payUpFront)
        #expect(coverage.label == "4/4")
        #expect(coverage.isComplete)
    }

    @Test func paidRowsWithoutPointDoNotCount() {
        let prices = [NewPromoPrice(territory: "USA", pricePointId: "pp-usa"), NewPromoPrice(territory: "CZE", pricePointId: nil)]
        let coverage = PromoCoverage(prices: prices, available: available, mode: .payAsYouGo)
        #expect(coverage.covered == 1)
        #expect(coverage.missing == ["CZE", "DEU", "JPN"])
        #expect(!coverage.isComplete)
    }

    @Test func freeTrialRowsCountWithoutPoint() {
        let prices = available.map { NewPromoPrice(territory: $0, pricePointId: nil) }
        #expect(PromoCoverage(prices: prices, available: available, mode: .freeTrial).isComplete)
    }

    @Test func pricesOutsideAvailabilityAreReported() {
        let prices = (available.union(["KOR"])).map { NewPromoPrice(territory: $0, pricePointId: "pp") }
        let coverage = PromoCoverage(prices: prices, available: available, mode: .payUpFront)
        #expect(coverage.label == "4/4")
        #expect(coverage.outsideAvailability == ["KOR"])
        #expect(!coverage.isComplete)
    }
}
