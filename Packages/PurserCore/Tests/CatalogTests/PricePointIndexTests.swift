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

    @Test func appleIdsRoundTripThroughTheSharedPrefix() throws {
        // Apple's ids are base64 of {"s":<product>,"t":<territory>,"p":<tier>}: a ladder shares all but the last characters.
        func appleId(_ product: String, _ territory: String, _ tier: Int) -> String {
            Data("{\"s\":\"\(product)\",\"t\":\"\(territory)\",\"p\":\"\(10000 + tier)\"}".utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
        }
        var points: [PricePoint] = []
        for product in ["1562169432", "6633433570"] {
            for territory in ["USA", "AFG"] as [TerritoryCode] {
                for tier in 1...120 {
                    points.append(PricePoint(id: appleId(product, territory.rawValue, tier), productAscId: product, territory: territory,
                                             planType: .upfront, customerPrice: Decimal(tier) - Decimal(string: "0.01")!,
                                             proceeds: Decimal(tier) * Decimal(string: "0.7")!))
                }
            }
        }
        let index = PricePointIndex(points.shuffled())
        for point in points {
            #expect(index.point(id: point.id) == point)
        }
        let ladder = index.ladder(productAscId: "6633433570", territory: "AFG", planType: .upfront)
        #expect(ladder.count == 120)
        #expect(ladder.prices == ladder.prices.sorted())
        #expect(Array(ladder) == points.filter { $0.productAscId == "6633433570" && $0.territory == "AFG" })
        #expect(index.point(id: appleId("1562169432", "USA", 121)) == nil)
    }

    @Test func idsOfAnyShapeAreFoundAndNothingElseIs() {
        // One ladder per group: no shared prefix, one id a prefix of another, a split inside a multi-byte character,
        // a combining mark after the shared part, a single point and an empty id.
        let groups: [(TerritoryCode, [String])] = [
            ("USA", ["a", "ab", "abc", "zzz"]),
            ("CZE", ["čaj-1", "čaj-2", "ča"]),
            ("JPN", ["日本-10", "日本-11", "日木"]),
            ("FRA", ["ex", "e\u{301}", "e\u{301}y"]),
            ("DEU", ["only-one"]),
            ("ITA", ["", "x"]),
        ]
        var points: [PricePoint] = []
        for (territory, ids) in groups {
            for (offset, id) in ids.enumerated() {
                points.append(PricePoint(id: id, productAscId: "6500000001", territory: territory, planType: .upfront,
                                         customerPrice: Decimal(offset), proceeds: nil))
            }
        }
        let index = PricePointIndex(points)
        for point in points {
            #expect(index.point(id: point.id) == point)
        }
        for missing in ["abcd", "č", "čaj-", "čaj-3", "日", "日本-1", "日本", "zz", "e", "only", "only-one-", "y"] {
            #expect(index.point(id: missing) == nil, "\(missing)")
        }
    }

    @Test func agreesWithAPlainScanOfEveryPoint() {
        var random = SeededRandom(seed: 7)
        let territories: [TerritoryCode] = ["USA", "CZE", "JPN"]
        var points: [PricePoint] = []
        for index in 0..<2_000 {
            let product = "65000000\(random.next(below: 3))"
            let planType: PlanType? = [.upfront, .monthly, nil][random.next(below: 3)]
            points.append(PricePoint(id: "pp-\(product)-\(index)", productAscId: product, territory: territories[random.next(below: 3)],
                                     planType: planType, customerPrice: Decimal(random.next(below: 400)) / 4,
                                     proceeds: random.next(below: 2) == 0 ? nil : Decimal(random.next(below: 300)) / 4))
        }
        let index = PricePointIndex(points)
        for point in points {
            #expect(index.point(id: point.id) == point)
        }
        for product in ["650000000", "650000001", "650000002"] {
            for territory in territories {
                for planType in [PlanType.upfront, .monthly, nil] {
                    let expected = points.filter { $0.productAscId == product && $0.territory == territory && $0.planType == planType }
                        .sorted { ($0.customerPrice, $0.id) < ($1.customerPrice, $1.id) }
                    #expect(index.points(productAscId: product, territory: territory, planType: planType) == expected)
                    for amount in [Decimal(0), Decimal(string: "12.3")!, Decimal(50), Decimal(200)] {
                        let nearest = expected.min { a, b in
                            let da = abs(a.customerPrice - amount), db = abs(b.customerPrice - amount)
                            return da == db ? a.customerPrice < b.customerPrice : da < db
                        }
                        #expect(index.nearest(to: amount, productAscId: product, territory: territory, planType: planType) == nearest)
                        #expect(index.floor(atMost: amount, productAscId: product, territory: territory, planType: planType)
                                == expected.last { $0.customerPrice <= amount })
                    }
                }
            }
        }
    }
}

/// A small deterministic generator (SplitMix64), so a failing case can be reproduced.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(below bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}
