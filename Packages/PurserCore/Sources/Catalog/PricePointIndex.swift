import Foundation
import Domain

public struct PricePointIndex: Sendable {
    private struct Key: Hashable, Sendable {
        var productAscId: String
        var territory: TerritoryCode
        var planType: PlanType?
    }

    private let byKey: [Key: [PricePoint]]
    private let byId: [String: PricePoint]

    public init(_ points: [PricePoint]) {
        byKey = Dictionary(grouping: points) { Key(productAscId: $0.productAscId, territory: $0.territory, planType: $0.planType) }
            .mapValues { $0.sorted { ($0.customerPrice, $0.id) < ($1.customerPrice, $1.id) } }
        byId = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Sorted ascending by customerPrice.
    public func points(productAscId: String, territory: TerritoryCode, planType: PlanType?) -> [PricePoint] {
        byKey[Key(productAscId: productAscId, territory: territory, planType: planType)] ?? []
    }

    public func point(id: String) -> PricePoint? {
        byId[id]
    }

    /// Smallest absolute difference; on a tie the cheaper point wins.
    public func nearest(to amount: Decimal, productAscId: String, territory: TerritoryCode, planType: PlanType?) -> PricePoint? {
        points(productAscId: productAscId, territory: territory, planType: planType).min { a, b in
            let da = abs(a.customerPrice - amount)
            let db = abs(b.customerPrice - amount)
            return da == db ? a.customerPrice < b.customerPrice : da < db
        }
    }

    /// Highest point with customerPrice <= amount.
    public func floor(atMost amount: Decimal, productAscId: String, territory: TerritoryCode, planType: PlanType?) -> PricePoint? {
        points(productAscId: productAscId, territory: territory, planType: planType).last { $0.customerPrice <= amount }
    }
}
