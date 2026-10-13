import Foundation
import Domain
import Catalog
import Policy

/// How the price of one intro cell is determined.
enum IntroAmount {
    case free
    case fixed(Decimal)
    case percentOfRegular(Decimal)
}

extension PlanBuilder {
    mutating func addIntro(_ spec: IntroPlanSpec) {
        summary.canary = spec.canary
        for subscriptionId in spec.subscriptionIds.sorted() where spec.filter.includes(product: subscriptionId) {
            guard let sub = requireSubscription(subscriptionId) else { continue }
            var nominal = spec.nominalDiscount
            if nominal == nil, case let .percentOfRegular(share) = spec.pricing { nominal = 1 - share }
            if let nominal, spec.mode != .freeTrial { summary.nominalDiscounts[subscriptionId] = nominal }
            var territories: [TerritoryCode]
            if case let .table(amounts) = spec.pricing {
                territories = amounts.map(\.territory).filter { spec.filter.includes(territory: $0) }.sorted()
            } else {
                territories = sub.availableTerritories.filter { spec.filter.includes(territory: $0) }.sorted()
            }
            if spec.canary { territories = Array(territories.filter { sub.availableTerritories.contains($0) }.prefix(1)) }
            for territory in territories {
                switch spec.pricing {
                case .freeTrial:
                    addIntroTarget(sub, territory: territory, mode: .freeTrial, duration: spec.duration, periods: 1, amount: .free,
                                   nominal: nil, startDate: spec.startDate, endDate: spec.endDate)
                case let .trialLengths(lengths):
                    addIntroTarget(sub, territory: territory, mode: .freeTrial, duration: lengths[territory] ?? spec.duration, periods: 1,
                                   amount: .free, nominal: nil, startDate: spec.startDate, endDate: spec.endDate)
                case let .percentOfRegular(share):
                    addIntroTarget(sub, territory: territory, mode: spec.mode, duration: spec.duration, periods: spec.numberOfPeriods,
                                   amount: .percentOfRegular(share), nominal: spec.nominalDiscount,
                                   startDate: spec.startDate, endDate: spec.endDate)
                case let .table(amounts):
                    guard let amount = amounts.first(where: { $0.territory == territory })?.amount else { continue }
                    addIntroTarget(sub, territory: territory, mode: spec.mode, duration: spec.duration, periods: spec.numberOfPeriods,
                                   amount: .fixed(amount), nominal: spec.nominalDiscount, startDate: spec.startDate, endDate: spec.endDate)
                }
            }
        }
    }

    /// One desired intro: start defaults to today + minLeadDays on approved products (R4); paid prices snap down (S4)
    /// to the highest point <= min(amount, (1 - nominal) x lowest regular price in the intro window) (I5, flag LIMITED_I5).
    mutating func addIntroTarget(_ sub: SubscriptionInfo, territory: TerritoryCode, mode: OfferMode, duration: OfferDuration,
                                 periods: Int, amount: IntroAmount, nominal: Decimal?, startDate: CalendarDate?, endDate: CalendarDate?) {
        let key = PriceKey(subscriptionId: sub.ascId, territory: territory, planType: .upfront)
        guard sub.availableTerritories.contains(territory) else { return unavailable(key.introCell, territory) }
        let start = startDate ?? (sub.state == .approved ? today.adding(days: AppleConstants.minLeadDays) : nil)
        var point: PricePoint?
        var flags: [ItemFlag] = []
        if mode != .freeTrial {
            let multiplier = OfferMath.regularMultiplier(mode: mode, duration: duration, period: sub.period)
            let lowest = RegularTimeline.prices(snapshot, key: key, today: today, intent: regularIntents[key],
                                                from: start ?? today, to: endDate).min().map { $0 * multiplier }
            var target: Decimal
            switch amount {
            case .free:
                return
            case let .fixed(value):
                target = value
            case let .percentOfRegular(share):
                guard let lowest else {
                    verdicts.append(Verdict(rule: "S4", severity: .block(.cell), cell: key.introCell, message: "The regular price the intro is calculated from is missing."))
                    return
                }
                target = share * lowest
            }
            if let nominal, let lowest, (1 - nominal) * lowest < target {
                target = (1 - nominal) * lowest
                flags.append(.limitedByI5)
            }
            guard let snapped = snap(target, product: sub.ascId, territory: territory, planType: .upfront, direction: .down,
                                     cell: key.introCell) else { return }
            point = snapped
        }
        introIntents[key] = IntroIntent(key: key, mode: mode, duration: duration, periods: mode == .payAsYouGo ? periods : 1,
                                        startDate: start, endDate: endDate, point: point, flags: flags)
    }
}
