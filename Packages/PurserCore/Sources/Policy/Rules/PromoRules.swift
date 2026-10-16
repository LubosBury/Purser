import Foundation
import Domain
import Catalog

/// Suggests offer codes in the form <base>_v<n> that were never used (rule O1).
public enum OfferCodeSuggester {
    public static func suggest(for code: String, used: Set<String>) -> String {
        let base = code.replacing(/_v[0-9]+$/, with: "")
        if !used.contains(base) && base == code { return base }
        var n = 2
        while used.contains("\(base)_v\(n)") { n += 1 }
        return "\(base)_v\(n)"
    }
}

/// O1: an offer code that has ever been seen can never be used again.
struct O1OfferCodeRule: PlanRule {
    let id: RuleID = "O1"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        var seenInPlan: Set<String> = []
        var verdicts: [Verdict] = []
        for item in context.items {
            guard let offer = item.newPromo else { continue }
            if context.snapshot.offerCodesEverSeen.contains(offer.offerCode) || seenInPlan.contains(offer.offerCode) {
                let suggestion = OfferCodeSuggester.suggest(for: offer.offerCode, used: context.snapshot.offerCodesEverSeen.union(seenInPlan))
                verdicts.append(.block(id, .plan, item.cell, "The code \(offer.offerCode) was already used and cannot be used again; suggestion: \(suggestion)."))
            }
            seenInPlan.insert(offer.offerCode)
        }
        return verdicts
    }
}

/// O2: at most maxPromoOffersPerSubscription offers per subscription after the plan.
struct O2PromoCountRule: PlanRule {
    let id: RuleID = "O2"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let projection = PlanProjection(snapshot: context.snapshot, items: context.items, today: context.today)
        let subscriptions = Set(context.items.filter { $0.newPromo != nil }.map(\.cell.productAscId))
        return subscriptions.sorted().compactMap { sub -> Verdict? in
            let count = projection.promoOffers(subscriptionId: sub).count
            guard count > AppleConstants.maxPromoOffersPerSubscription else { return nil }
            return .block(id, .plan, nil, "The subscription \(sub) would have \(count) promotional offers; the maximum is \(AppleConstants.maxPromoOffersPerSubscription).")
        }
    }
}

/// O3: a price for every territory where the subscription is available.
struct O3PromoCoverageRule: PlanRule {
    let id: RuleID = "O3"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            let territories: Set<TerritoryCode>
            switch item.payload {
            case let .createPromo(offer): territories = Set(offer.prices.map(\.territory))
            case let .replacePromoPrices(_, prices): territories = Set(prices.map(\.territory))
            default: return nil
            }
            guard let available = context.snapshot.subscriptions[item.cell.productAscId]?.availableTerritories else { return nil }
            let missing = available.subtracting(territories).map(\.rawValue).sorted()
            guard !missing.isEmpty else { return nil }
            return .block(id, .plan, item.cell, "Prices are missing for \(missing.count) territories: \(Format.list(missing)).")
        }
    }
}

/// O5*: a PAY_AS_YOU_GO promo is cheaper than the regular price now and after every scheduled change;
/// a PAY_UP_FRONT promo at or above the regular price only warns.
struct O5PromoBelowRegularRule: PlanRule, InvariantRule {
    let id: RuleID = "O5"

    struct Violation { var offer: PromoOffer; var territory: TerritoryCode; var price: Decimal; var regular: Decimal }

    func evaluate(_ context: PolicyContext) -> [Verdict] {
        let projection = PlanProjection(snapshot: context.snapshot, items: context.items, today: context.today)
        let subscriptions = Set(context.items.map(\.cell.productAscId)).filter { context.snapshot.subscriptions[$0] != nil }
        var verdicts: [Verdict] = []
        for sub in subscriptions.sorted() {
            for offer in projection.promoOffers(subscriptionId: sub) {
                let found = violations(offer, projection)
                guard !found.isEmpty else { continue }
                let list = Format.list(found.map { "\($0.territory) (\($0.price) ≥ \($0.regular))" })
                let cell: CellKey = .promo(subscriptionId: sub, offerCode: offer.offerCode)
                if offer.mode == .payAsYouGo {
                    verdicts.append(.block(id, .plan, cell, "The PAYG promo \(offer.offerCode) is not cheaper than the regular price in: \(list)."))
                } else {
                    verdicts.append(.warn(id, cell, "The promo \(offer.offerCode) is not cheaper than the regular price in: \(list)."))
                }
            }
        }
        return verdicts
    }

    func check(_ snapshot: CatalogSnapshot, today: CalendarDate) -> [Verdict] {
        let projection = PlanProjection(snapshot: snapshot, items: [], today: today)
        var verdicts: [Verdict] = []
        for offer in snapshot.promoOffers.sorted(by: { ($0.subscriptionId, $0.offerCode) < ($1.subscriptionId, $1.offerCode) }) {
            let cell: CellKey = .promo(subscriptionId: offer.subscriptionId, offerCode: offer.offerCode)
            for v in violations(offer, projection) {
                let text = "The promo \(offer.offerCode) in \(v.territory): \(v.price) is not cheaper than the regular price \(v.regular)."
                verdicts.append(offer.mode == .payAsYouGo ? .block(id, .plan, cell, text) : .warn(id, cell, text))
            }
        }
        return verdicts
    }

    private func violations(_ offer: PromoOffer, _ projection: PlanProjection) -> [Violation] {
        guard offer.mode != .freeTrial, let period = projection.snapshot.subscriptions[offer.subscriptionId]?.period else { return [] }
        let multiplier = OfferMath.regularMultiplier(mode: offer.mode, duration: offer.duration, period: period)
        var result: [Violation] = []
        for price in offer.prices {
            guard let amount = price.customerPrice ?? price.pricePointId.flatMap({ projection.snapshot.pricePoints.point(id: $0)?.customerPrice }) else { continue }
            let regulars = projection.regularPrices(offer.subscriptionId, price.territory, offer.planType, from: projection.today, to: nil)
            if let hit = regulars.first(where: { amount >= $0.price * multiplier }) {
                result.append(Violation(offer: offer, territory: price.territory, price: amount, regular: hit.price * multiplier))
            }
        }
        return result
    }
}

/// O6: repricing or deleting an offer needs C2 (effect on customers inside the offer is undocumented).
struct O6PromoChangeRule: PlanRule {
    let id: RuleID = "O6"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            switch item.payload {
            case .replacePromoPrices:
                return .c2(id, item.cell, "Repricing a promotional offer: the whole set of prices is sent.", riskClass: "O6 promo reprice or deletion")
            case .deletePromo:
                return .c2(id, item.cell, "Deleting a promotional offer.", riskClass: "O6 promo reprice or deletion")
            default:
                return nil
            }
        }
    }
}

/// O7: deleting an offer burns its code forever; it needs C2.
struct O7PromoDeleteRule: PlanRule {
    let id: RuleID = "O7"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard case .deletePromo = item.payload, case let .promo(_, code) = item.cell else { return nil }
            return .c2(id, item.cell, "The code \(code) can never be used again after the deletion.", riskClass: "O7 promo offer deletion")
        }
    }
}
