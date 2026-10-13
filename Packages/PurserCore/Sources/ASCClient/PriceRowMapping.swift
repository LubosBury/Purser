import Foundation
import Domain

private let posix = Locale(identifier: "en_US_POSIX")

private func decimal(_ string: String?) -> Decimal? {
    guard let string, !string.isEmpty else { return nil }
    return Decimal(string: string, locale: posix)
}

private func date(_ string: String?, field: String, row: String?) throws -> CalendarDate? {
    guard let string else { return nil }
    guard let parsed = CalendarDate(iso: string) else {
        throw ASCError.decoding("\(field) '\(string)' of row \(row ?? "?") is not YYYY-MM-DD")
    }
    return parsed
}

/// Mapping rules for `subscriptionPromotionalOfferPrices` rows (O4, spike S7).
/// ASCMapping.promotionalOffer (LiveASCClient+Reading.swift) extracts the primitives from the JSON:API document and calls this.
public enum PromoPriceMapping {
    public static func make(rowId: String?, territoryId: String?, pricePointId: String?,
                            customerPrice: String?, offerMode: OfferMode) throws -> PromoPrice {
        guard let territoryId, !territoryId.isEmpty else {
            throw ASCError.decoding("promo price row \(rowId ?? "?") has no territory")
        }
        if offerMode == .freeTrial {
            return PromoPrice(ascId: rowId, territory: TerritoryCode(territoryId), pricePointId: nil, customerPrice: nil)
        }
        guard let pricePointId, !pricePointId.isEmpty else {
            throw ASCError.decoding("paid promo price row \(rowId ?? "?") has no price point")
        }
        return PromoPrice(ascId: rowId, territory: TerritoryCode(territoryId), pricePointId: pricePointId,
                          customerPrice: decimal(customerPrice))
    }
}

/// Mapping rules for `inAppPurchasePrices` rows of a price schedule (L1, spike S10).
public enum IAPManualPriceMapping {
    public static func make(rowId: String?, territoryId: String?, pricePointId: String?, startDate: String?,
                            endDate: String?, customerPrice: String?) throws -> IAPManualPrice {
        guard let territoryId, !territoryId.isEmpty else {
            throw ASCError.decoding("IAP price row \(rowId ?? "?") has no territory")
        }
        guard let pricePointId, !pricePointId.isEmpty else {
            throw ASCError.decoding("IAP price row \(rowId ?? "?") has no price point")
        }
        guard let price = decimal(customerPrice) else {
            throw ASCError.decoding("IAP price row \(rowId ?? "?") has no customerPrice (include inAppPurchasePricePoint)")
        }
        return IAPManualPrice(ascId: rowId, territory: TerritoryCode(territoryId), pricePointId: pricePointId,
                              startDate: try date(startDate, field: "startDate", row: rowId),
                              endDate: try date(endDate, field: "endDate", row: rowId), customerPrice: price)
    }
}
