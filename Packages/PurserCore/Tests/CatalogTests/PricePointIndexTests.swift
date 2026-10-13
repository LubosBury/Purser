import Foundation
import Testing
import Catalog
import Domain
import PurserTestSupport

@Suite struct PricePointIndexTests {
    private let index = PricePointIndex([
        Sample.pricePoint(territory: "USA", price: "34.99"),
        Sample.pricePoint(territory: "USA", price: "29.99"),
        Sample.pricePoint(territory: "USA", price: "32.99"),
        Sample.pricePoint(territory: "CZE", price: "799"),
        Sample.pricePoint("6600000001", territory: "USA", price: "49.99", planType: nil),
    ])

    @Test func pointsAreSortedAndKeyedByProductTerritoryAndPlanType() {
        #expect(index.points(productAscId: "6500000001", territory: "USA", planType: .upfront).map(\.customerPrice)
                == [Decimal(string: "29.99")!, Decimal(string: "32.99")!, Decimal(string: "34.99")!])
        #expect(index.points(productAscId: "6500000001", territory: "USA", planType: .monthly).isEmpty)
        #expect(index.points(productAscId: "6600000001", territory: "USA", planType: nil).count == 1)
        #expect(index.point(id: "pp-CZE-799")?.territory == "CZE")
        #expect(index.point(id: "missing") == nil)
    }

    @Test func nearestPrefersTheCheaperPointOnATie() {
        #expect(index.nearest(to: Decimal(string: "33.50")!, productAscId: "6500000001", territory: "USA", planType: .upfront)?.id == "pp-USA-32.99")
        #expect(index.nearest(to: Decimal(string: "31.49")!, productAscId: "6500000001", territory: "USA", planType: .upfront)?.id == "pp-USA-29.99")
        #expect(index.nearest(to: Decimal(string: "33.99")!, productAscId: "6500000001", territory: "USA", planType: .upfront)?.id == "pp-USA-32.99")
        #expect(index.nearest(to: 10, productAscId: "6500000001", territory: "DEU", planType: .upfront) == nil)
    }

    @Test func floorReturnsTheHighestPointNotAboveTheAmount() {
        #expect(index.floor(atMost: Decimal(string: "34.98")!, productAscId: "6500000001", territory: "USA", planType: .upfront)?.id == "pp-USA-32.99")
        #expect(index.floor(atMost: Decimal(string: "34.99")!, productAscId: "6500000001", territory: "USA", planType: .upfront)?.id == "pp-USA-34.99")
        #expect(index.floor(atMost: Decimal(string: "29.98")!, productAscId: "6500000001", territory: "USA", planType: .upfront) == nil)
    }
}
