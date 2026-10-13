import Foundation
import Domain
import Catalog
import Policy

extension PlanBuilder {
    mutating func addPromo(_ spec: PromoPlanSpec) {
        switch spec.action {
        case let .create(subscriptionId, offerCode, name, mode, duration, numberOfPeriods, pricing):
            guard let sub = requireSubscription(subscriptionId) else { return }
            let cell: CellKey = .promo(subscriptionId: subscriptionId, offerCode: offerCode)
            guard let prices = promoPrices(sub, mode: mode, duration: duration, pricing: pricing, existing: nil, cell: cell) else { return }
            let periods = mode == .payAsYouGo ? numberOfPeriods : 1
            let offer = NewPromoOffer(subscriptionId: subscriptionId, offerCode: offerCode, name: name, mode: mode, duration: duration,
                                      numberOfPeriods: periods, planType: .upfront, prices: prices.map(\.new))
            let target = PromoOffer(ascId: PlannedRow.ascId, subscriptionId: subscriptionId, offerCode: offerCode, name: name, mode: mode,
                                    duration: duration, numberOfPeriods: periods, planType: .upfront, prices: prices.map(\.row))
            sink.add(cell, .createPromo(offer), before: .promo(nil), target: .promo(target), rules: ["O1", "O3", "O4"])

        case let .reprice(offerAscId, pricing):
            guard let offer = promoOffer(offerAscId), let sub = requireSubscription(offer.subscriptionId) else { return }
            let cell: CellKey = .promo(subscriptionId: offer.subscriptionId, offerCode: offer.offerCode)
            guard let prices = promoPrices(sub, mode: offer.mode, duration: offer.duration, pricing: pricing, existing: offer, cell: cell) else { return }
            let unchanged = Set(prices.map { "\($0.new.territory):\($0.new.pricePointId ?? "-")" })
                == Set(offer.prices.map { "\($0.territory):\($0.pricePointId ?? "-")" })
            if unchanged { return }
            var target = offer
            target.prices = prices.map(\.row)
            let seq = sink.add(cell, .replacePromoPrices(ascId: offer.ascId, prices: prices.map(\.new)), before: .promo(offer),
                               target: .promo(target), rules: ["O3", "O6"])
            if offer.mode == .payAsYouGo { paygPromoPatches[offer.subscriptionId, default: []].append(seq) }

        case let .delete(offerAscId, confirmedUnusedByApp):
            guard let offer = promoOffer(offerAscId) else { return }
            let cell: CellKey = .promo(subscriptionId: offer.subscriptionId, offerCode: offer.offerCode)
            if !confirmedUnusedByApp {
                verdicts.append(Verdict(rule: "O7", severity: .block(.plan), cell: cell,
                                        message: "Deleting \(offer.offerCode) requires the confirmation “the app no longer uses \(offer.offerCode)”."))
            }
            sink.add(cell, .deletePromo(ascId: offer.ascId), before: .promo(offer), target: .promo(nil), rules: ["O6", "O7"])
        }
    }

    mutating func promoOffer(_ ascId: String) -> PromoOffer? {
        if let offer = snapshot.promoOffers.first(where: { $0.ascId == ascId }) { return offer }
        verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: nil, message: "The promotional offer \(ascId) is not in the catalog."))
        return nil
    }

    /// Full price set over the available territories (O3). With `existing`, territories the pricing does not cover keep their price.
    mutating func promoPrices(_ sub: SubscriptionInfo, mode: OfferMode, duration: OfferDuration, pricing: IntroPricing,
                              existing: PromoOffer?, cell: CellKey) -> [(new: NewPromoPrice, row: PromoPrice)]? {
        if case .trialLengths = pricing {
            verdicts.append(Verdict(rule: "I2", severity: .block(.plan), cell: cell, message: "A promo has one duration for all territories; per-territory durations are not possible."))
            return nil
        }
        if (mode == .freeTrial) != (pricing == .freeTrial) {
            verdicts.append(Verdict(rule: "O4", severity: .block(.plan), cell: cell, message: "A free trial promo has no prices and a paid promo must have them."))
            return nil
        }
        let multiplier = OfferMath.regularMultiplier(mode: mode, duration: duration, period: sub.period)
        var result: [(new: NewPromoPrice, row: PromoPrice)] = []
        for territory in sub.availableTerritories.sorted() {
            var amount: Decimal?
            switch pricing {
            case .freeTrial:
                result.append((NewPromoPrice(territory: territory, pricePointId: nil), PromoPrice(ascId: nil, territory: territory, pricePointId: nil, customerPrice: nil)))
                continue
            case let .percentOfRegular(share):
                amount = snapshot.regularPrice(subscriptionId: sub.ascId, territory: territory, planType: .upfront, on: today).map { share * $0 * multiplier }
            case let .table(amounts):
                amount = amounts.first { $0.territory == territory }?.amount
            case .trialLengths:
                amount = nil
            }
            if let amount {
                guard let point = snap(amount, product: sub.ascId, territory: territory, planType: .upfront, direction: .down, cell: cell) else { continue }
                result.append((NewPromoPrice(territory: territory, pricePointId: point.id),
                               PromoPrice(ascId: nil, territory: territory, pricePointId: point.id, customerPrice: point.customerPrice)))
            } else if let old = existing?.prices.first(where: { $0.territory == territory }) {
                result.append((NewPromoPrice(territory: territory, pricePointId: old.pricePointId), old))
            }
        }
        return result
    }
}
