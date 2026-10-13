import Foundation
import Domain

/// Maps write responses to K1 rows over the K5 JSON:API accessors. POST responses carry no price point, so `customerPrice`
/// is filled only when ASC includes the price point; the Executor never reads amounts from write responses (verify reads live rows).
package enum WriteResponses {
    static func primary(_ document: JSONAPIDocument?, type: String) throws -> JSONAPIResource {
        guard let resource = document?.data.first, resource.type == type else {
            throw ASCError.decoding("\(type): response has no primary resource")
        }
        return resource
    }

    /// Missing attribute -> the requested value; explicit null -> nil; a string -> the parsed date (or the requested value).
    static func date(_ resource: JSONAPIResource, _ key: String, fallback: CalendarDate?) -> CalendarDate? {
        guard let value = resource.attributes[key] else { return fallback }
        if case .null = value { return nil }
        return resource.string(key).flatMap { CalendarDate(iso: $0) } ?? fallback
    }

    static func includedPrice(_ document: JSONAPIDocument?, type: String, id: String?) -> Decimal? {
        guard let id, let raw = document?.includedResource(type: type, id: id)?.string("customerPrice") else { return nil }
        return Decimal(string: raw)
    }

    package static func regularPriceRow(_ document: JSONAPIDocument?, request r: NewRegularPrice) throws -> RegularPriceRow {
        let resource = try primary(document, type: "subscriptionPrices")
        return RegularPriceRow(
            ascId: resource.id, subscriptionId: r.subscriptionId, territory: r.territory, planType: r.planType,
            rawPlanType: resource.string("planType"),
            startDate: date(resource, "startDate", fallback: r.startDate),
            preserved: resource.bool("preserved") ?? false,
            pricePointId: r.pricePointId,
            customerPrice: includedPrice(document, type: "subscriptionPricePoints", id: r.pricePointId) ?? 0)
    }

    package static func introRow(_ document: JSONAPIDocument?, request o: NewIntroOffer) throws -> IntroOfferRow {
        let resource = try primary(document, type: "subscriptionIntroductoryOffers")
        return IntroOfferRow(
            ascId: resource.id, subscriptionId: o.subscriptionId, territory: o.territory, planType: o.planType,
            rawPlanType: resource.string("targetSubscriptionPlanType"),
            mode: o.mode, duration: o.duration, numberOfPeriods: o.numberOfPeriods,
            startDate: date(resource, "startDate", fallback: o.startDate),
            endDate: date(resource, "endDate", fallback: o.endDate),
            pricePointId: o.pricePointId,
            customerPrice: includedPrice(document, type: "subscriptionPricePoints", id: o.pricePointId))
    }

    package static func promoOffer(_ document: JSONAPIDocument?, request o: NewPromoOffer) throws -> PromoOffer {
        let resource = try primary(document, type: "subscriptionPromotionalOffers")
        var createdIds: [TerritoryCode: String] = [:]
        for price in document?.included ?? [] where price.type == "subscriptionPromotionalOfferPrices" {
            if let territory = price.relatedID("territory") { createdIds[TerritoryCode(territory)] = price.id }
        }
        let prices = o.prices.map {
            PromoPrice(ascId: createdIds[$0.territory], territory: $0.territory, pricePointId: $0.pricePointId, customerPrice: nil)
        }
        return PromoOffer(ascId: resource.id, subscriptionId: o.subscriptionId, offerCode: o.offerCode, name: o.name,
                          mode: o.mode, duration: o.duration, numberOfPeriods: o.numberOfPeriods, planType: o.planType,
                          prices: prices)
    }
}
