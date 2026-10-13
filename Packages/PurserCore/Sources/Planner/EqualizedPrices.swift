import Foundation
import Catalog
import Domain

/// Turns "this price in one territory" into a table for every territory, from Apple's equalizations of a price point.
public enum EqualizedPrices {
    /// The price point of exactly `amount` in the base territory; nil when the amount is not on the product's ladder.
    public static func basePoint(in index: PricePointIndex, productAscId: String, territory: TerritoryCode, planType: PlanType?,
                                 amount: Decimal) -> PricePoint? {
        index.points(productAscId: productAscId, territory: territory, planType: planType).first { $0.customerPrice == amount }
    }

    /// Lines "CODE<TAB>price" sorted by territory, in the format PastedAmountTable reads. The base territory keeps the
    /// base price even if the equalizations name it again.
    public static func tableText(base: PricePoint, equalized: [PricePoint]) -> String {
        var prices: [TerritoryCode: Decimal] = [:]
        for point in equalized { prices[point.territory] = point.customerPrice }
        prices[base.territory] = base.customerPrice
        return prices.sorted { $0.key < $1.key }.map { "\($0.key.rawValue)\t\($0.value)" }.joined(separator: "\n")
    }
}
