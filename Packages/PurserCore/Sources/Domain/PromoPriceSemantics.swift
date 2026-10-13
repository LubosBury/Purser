import Foundation

/// Promo price-set semantics (rules O3, O4, O6; spike S7).
public enum PromoPriceSemantics {
    /// The price set ASC holds after `PATCH /v1/subscriptionPromotionalOffers/{id}`.
    /// `replaces == true`: the patch becomes the whole set. Otherwise rows merge by territory and the patch wins.
    public static func applyPatch(existing: [NewPromoPrice], patch: [NewPromoPrice], replaces: Bool) -> [NewPromoPrice] {
        if replaces { return patch.sorted { $0.territory < $1.territory } }
        var byTerritory: [TerritoryCode: NewPromoPrice] = [:]
        for price in existing { byTerritory[price.territory] = price }
        for price in patch { byTerritory[price.territory] = price }
        return byTerritory.values.sorted { $0.territory < $1.territory }
    }

    /// Territory -> price point id for comparisons ("-" = no point). FREE_TRIAL rows never carry a point (O4),
    /// whatever ASC echoes back.
    public static func comparablePrices(mode: OfferMode, prices: [PromoPrice]) -> [TerritoryCode: String] {
        var out: [TerritoryCode: String] = [:]
        for price in prices {
            out[price.territory] = mode == .freeTrial ? "-" : (price.pricePointId ?? "-")
        }
        return out
    }

    /// True when the live offer satisfies the target. Asc ids of offers and rows and customer prices are ignored.
    public static func matches(live: PromoOffer?, target: PromoOffer?) -> Bool {
        switch (live, target) {
        case (nil, nil):
            return true
        case let (l?, t?):
            return l.subscriptionId == t.subscriptionId && l.offerCode == t.offerCode && l.mode == t.mode
                && l.duration == t.duration && l.numberOfPeriods == t.numberOfPeriods && l.planType == t.planType
                && comparablePrices(mode: l.mode, prices: l.prices) == comparablePrices(mode: t.mode, prices: t.prices)
        default:
            return false
        }
    }
}
