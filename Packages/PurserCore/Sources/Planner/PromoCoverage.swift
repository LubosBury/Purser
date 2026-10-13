import Foundation
import Domain

/// Coverage meter for rule O3: a price for every territory where the subscription is available.
public struct PromoCoverage: Hashable, Sendable {
    public var covered: Int
    public var required: Int
    public var missing: [TerritoryCode]
    public var outsideAvailability: [TerritoryCode]

    /// Paid rows count only with a price point; FREE_TRIAL rows count by territory alone (O4).
    public init(prices: [NewPromoPrice], available: Set<TerritoryCode>, mode: OfferMode) {
        let priced = Set(prices.filter { mode == .freeTrial || $0.pricePointId != nil }.map(\.territory))
        covered = priced.intersection(available).count
        required = available.count
        missing = available.subtracting(priced).sorted()
        outsideAvailability = Set(prices.map(\.territory)).subtracting(available).sorted()
    }

    public var isComplete: Bool { missing.isEmpty && outsideAvailability.isEmpty }
    public var label: String { "\(covered)/\(required)" }
}
