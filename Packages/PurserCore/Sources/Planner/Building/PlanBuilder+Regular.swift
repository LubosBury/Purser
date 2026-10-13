import Foundation
import Domain
import Catalog
import Policy

extension PlanBuilder {
    mutating func addRegular(_ spec: RegularPlanSpec) {
        summary.skippedIntroReplacements.merge(spec.skipIntroReplacement) { _, new in new }
        for subscriptionId in spec.subscriptionIds.sorted() where spec.filter.includes(product: subscriptionId) {
            guard let sub = requireSubscription(subscriptionId) else { continue }
            for price in spec.prices.sorted(by: { $0.territory < $1.territory }) where spec.filter.includes(territory: price.territory) {
                addRegularTarget(sub, territory: price.territory, planType: spec.planType, amount: price.amount,
                                 startDate: spec.startDate, preserve: spec.preserveCurrentPrice)
            }
        }
        addPromoRepricing(spec.promoRepricing)
    }

    /// O5 (M4 Task 4.4): every PAYG promo offer in `repricing` is re-priced from the NEW regular price of each of its
    /// territories whose regular price drops (snapped down, M1 promoPrices); its other territories keep their price.
    /// Increases never touch promo offers. The PATCH goes through addPromo(.reprice), so paygPromoPatches makes the
    /// regular POSTs of the subscription depend on it (M1 "Order within a cell").
    mutating func addPromoRepricing(_ repricing: [String: IntroPricing]) {
        for (offerAscId, pricing) in repricing.sorted(by: { $0.key < $1.key }) {
            guard let offer = promoOffer(offerAscId) else { continue }
            guard offer.mode == .payAsYouGo else {
                verdicts.append(Verdict(rule: PlannerRule.plan, severity: .warn,
                                        cell: .promo(subscriptionId: offer.subscriptionId, offerCode: offer.offerCode),
                                        message: "The offer \(offer.offerCode) is not PAY_AS_YOU_GO; only PAYG offers are repriced with a regular price change."))
                continue
            }
            guard let sub = subscription(offer.subscriptionId) else { continue }
            let multiplier = OfferMath.regularMultiplier(mode: offer.mode, duration: offer.duration, period: sub.period)
            var amounts: [TerritoryAmount] = []
            for price in offer.prices {
                let key = PriceKey(subscriptionId: offer.subscriptionId, territory: price.territory, planType: offer.planType)
                guard let intent = regularIntents[key], intent.direction == .decrease else { continue }
                switch pricing {
                case let .percentOfRegular(share):
                    amounts.append(TerritoryAmount(territory: price.territory, amount: share * intent.point.customerPrice * multiplier))
                case let .table(rows):
                    if let row = rows.first(where: { $0.territory == price.territory }) { amounts.append(row) }
                case .freeTrial, .trialLengths:
                    continue
                }
            }
            guard !amounts.isEmpty else { continue }
            addPromo(PromoPlanSpec(action: .reprice(offerAscId: offerAscId, pricing: .table(amounts))))
        }
    }

    /// One desired regular price: snaps to the nearest point (S4) and decides direction and preserve (R1).
    mutating func addRegularTarget(_ sub: SubscriptionInfo, territory: TerritoryCode, planType: PlanType, amount: Decimal,
                                   startDate: CalendarDate?, preserve: Bool?) {
        let key = PriceKey(subscriptionId: sub.ascId, territory: territory, planType: planType)
        guard sub.availableTerritories.contains(territory) else { return unavailable(key.regularCell, territory) }
        guard let point = snap(amount, product: sub.ascId, territory: territory, planType: planType, direction: .nearest,
                               cell: key.regularCell) else { return }
        let current = snapshot.currentRegular(subscriptionId: sub.ascId, territory: territory, planType: planType, on: today)
        let scheduled = snapshot.scheduledRegular(subscriptionId: sub.ascId, territory: territory, planType: planType, on: today)
        let start = startDate ?? (current == nil ? nil : today.adding(days: AppleConstants.minLeadDays))
        if scheduled == nil, current?.pricePointId == point.id { return }
        if let scheduled, scheduled.pricePointId == point.id, scheduled.startDate == start { return }
        let direction: PriceDirection
        if let current { direction = point.customerPrice > current.customerPrice ? .increase : .decrease } else { direction = .initial }
        let preserveValue: Bool
        if direction == .increase {
            guard let preserve else { missingPreserve += 1; return }
            preserveValue = preserve
        } else {
            preserveValue = false
        }
        regularIntents[key] = RegularIntent(key: key, point: point, startDate: start, preserve: preserveValue, direction: direction)
    }

    /// I8: a regular change in a cell with one paid intro gets a replacement intro with the same start date
    /// (an intro that starts after the change keeps its own start) and the same ratio to the regular price.
    /// Cells with an explicit intro target, a skip reason, or more than one intro row are left to rule I8.
    mutating func addAutomaticIntroReplacements() {
        for (key, regular) in regularIntents.sorted(by: { $0.key < $1.key }) {
            guard introIntents[key] == nil, summary.skippedIntroReplacements[key.introCell] == nil,
                  case let .intro(current, future) = snapshot.cellState(key.introCell, on: today) else { continue }
            let day = regular.startDate ?? today
            let rows = [current, future].compactMap { $0 }
            guard rows.count == 1, let row = rows.first, let oldPrice = row.customerPrice, row.pricePointId != nil,
                  row.endDate.map({ $0 > day }) ?? true else { continue }
            let rowStart = row.startDate ?? today
            if future != nil, rowStart < day { continue }
            let start = max(day, rowStart)
            guard let oldRegular = snapshot.regularPrice(subscriptionId: key.subscriptionId, territory: key.territory,
                                                         planType: key.planType, on: start), oldRegular > 0,
                  let point = snap(oldPrice * regular.point.customerPrice / oldRegular, product: key.subscriptionId,
                                   territory: key.territory, planType: key.planType, direction: .down, cell: key.introCell) else { continue }
            introIntents[key] = IntroIntent(key: key, mode: row.mode, duration: row.duration, periods: row.numberOfPeriods,
                                            startDate: start, endDate: row.endDate, point: point, rules: ["I8"])
        }
    }
}
