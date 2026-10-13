import Foundation
import Domain

public enum Resolution: Hashable, Sendable {
    case targetFound(ascId: String?)
    case unchanged
    case diverged
}

/// Spec §5 "Idempotence" and §6 steps 2b and 4. Pure functions over CellState.
public enum Reconciler {
    // MARK: Live state vs expected state ("before")

    public static func matches(live: CellState, expected: CellState, today: CalendarDate) -> Bool {
        switch (live, expected) {
        case let (.regular(lc, ls), .regular(ec, es)):
            return regular(lc, ec, today) && regular(ls, es, today)
        case let (.intro(lc, lf), .intro(ec, ef)):
            return intro(lc, ec, today) && intro(lf, ef, today)
        case let (.promo(l), .promo(e)):
            return promo(l, e)
        case let (.iapSchedule(l), .iapSchedule(e)):
            return schedule(l, e)
        default:
            return false
        }
    }

    /// An expected nil startDate stands for "the day it was created": live nil or a day not after today.
    static func sameStart(_ live: CalendarDate?, _ expected: CalendarDate?, today: CalendarDate) -> Bool {
        if let expected { return live == expected }
        return live.map { $0 <= today } ?? true
    }

    static func regular(_ live: RegularPriceRow?, _ expected: RegularPriceRow?, _ today: CalendarDate) -> Bool {
        switch (live, expected) {
        case (nil, nil): return true
        case let (l?, e?):
            if e.ascId.isEmpty {
                return l.subscriptionId == e.subscriptionId && l.territory == e.territory && l.planType == e.planType
                    && l.pricePointId == e.pricePointId && sameStart(l.startDate, e.startDate, today: today)
            }
            return l == e
        default: return false
        }
    }

    static func intro(_ live: IntroOfferRow?, _ expected: IntroOfferRow?, _ today: CalendarDate) -> Bool {
        switch (live, expected) {
        case (nil, nil): return true
        case let (l?, e?):
            if e.ascId.isEmpty {
                return l.subscriptionId == e.subscriptionId && l.territory == e.territory && l.planType == e.planType
                    && l.mode == e.mode && l.duration == e.duration && l.numberOfPeriods == e.numberOfPeriods
                    && l.pricePointId == e.pricePointId && sameStart(l.startDate, e.startDate, today: today) && l.endDate == e.endDate
            }
            return l == e
        default: return false
        }
    }

    static func promo(_ live: PromoOffer?, _ expected: PromoOffer?) -> Bool {
        switch (live, expected) {
        case (nil, nil): return true
        case let (l?, e?):
            guard e.ascId.isEmpty || l.ascId == e.ascId,
                  l.subscriptionId == e.subscriptionId, l.offerCode == e.offerCode, l.name == e.name, l.mode == e.mode,
                  l.duration == e.duration, l.numberOfPeriods == e.numberOfPeriods, l.planType == e.planType,
                  l.prices.count == e.prices.count else { return false }
            return zip(l.prices, e.prices).allSatisfy { lp, ep in
                lp.territory == ep.territory && lp.pricePointId == ep.pricePointId
                    && (ep.ascId == nil || lp.ascId == ep.ascId)
                    && (ep.customerPrice == nil || lp.customerPrice == ep.customerPrice)
            }
        default: return false
        }
    }

    static func schedule(_ live: IAPSchedule?, _ expected: IAPSchedule?) -> Bool {
        switch (live, expected) {
        case (nil, nil): return true
        case let (l?, e?):
            guard e.scheduleId == nil || l.scheduleId == e.scheduleId, l.iapId == e.iapId, l.baseTerritory == e.baseTerritory,
                  l.manualPrices.count == e.manualPrices.count else { return false }
            return zip(l.manualPrices, e.manualPrices).allSatisfy { lp, ep in
                lp.territory == ep.territory && lp.pricePointId == ep.pricePointId && lp.startDate == ep.startDate
                    && lp.endDate == ep.endDate && (ep.ascId == nil || (lp.ascId == ep.ascId && lp.customerPrice == ep.customerPrice))
            }
        default: return false
        }
    }

    // MARK: Natural key satisfied by live rows

    static func regularMatches(_ p: NewRegularPrice, _ row: RegularPriceRow, _ today: CalendarDate) -> Bool {
        row.subscriptionId == p.subscriptionId && row.territory == p.territory && row.planType == p.planType
            && row.pricePointId == p.pricePointId && sameStart(row.startDate, p.startDate, today: today)
    }

    static func introMatches(_ o: NewIntroOffer, _ row: IntroOfferRow, _ today: CalendarDate) -> Bool {
        row.subscriptionId == o.subscriptionId && row.territory == o.territory && row.planType == o.planType
            && row.mode == o.mode && row.duration == o.duration && row.pricePointId == o.pricePointId
            && sameStart(row.startDate, o.startDate, today: today)
    }

    static func priceSet(_ prices: [(TerritoryCode, String?)]) -> [String] {
        prices.map { "\($0.0.rawValue)|\($0.1 ?? "-")" }.sorted()
    }

    static func manualSet(_ prices: [(TerritoryCode, String, CalendarDate?, CalendarDate?)]) -> [String] {
        prices.map { "\($0.0.rawValue)|\($0.1)|\($0.2?.iso ?? "-")|\($0.3?.iso ?? "-")" }.sorted()
    }

    public static func isSatisfied(_ payload: WritePayload, live: CellState, today: CalendarDate) -> Bool {
        switch (payload, live) {
        case let (.createRegularPrice(p), .regular(current, scheduled)):
            return [current, scheduled].contains { $0.map { regularMatches(p, $0, today) } ?? false }
        case let (.deleteRegularPrice(id), .regular(current, scheduled)):
            return current?.ascId != id && scheduled?.ascId != id
        case let (.createIntro(o), .intro(current, future)):
            return [current, future].contains { $0.map { introMatches(o, $0, today) } ?? false }
        case let (.endIntro(id, end), .intro(current, future)):
            return [current, future].contains { $0?.ascId == id && $0?.endDate == end }
        case let (.deleteIntro(id), .intro(current, future)):
            return current?.ascId != id && future?.ascId != id
        case let (.createPromo(o), .promo(offer)):
            return offer?.offerCode == o.offerCode && offer?.subscriptionId == o.subscriptionId
        case let (.replacePromoPrices(id, prices), .promo(offer)):
            guard let offer, offer.ascId == id else { return false }
            return priceSet(offer.prices.map { ($0.territory, $0.pricePointId) }) == priceSet(prices.map { ($0.territory, $0.pricePointId) })
        case let (.deletePromo(id), .promo(offer)):
            return offer?.ascId != id
        case let (.replaceIAPSchedule(s), .iapSchedule(schedule)):
            guard let schedule, schedule.iapId == s.iapId, schedule.baseTerritory == s.baseTerritory else { return false }
            return manualSet(schedule.manualPrices.map { ($0.territory, $0.pricePointId, $0.startDate, $0.endDate) })
                == manualSet(s.manualPrices.map { ($0.territory, $0.pricePointId, $0.startDate, $0.endDate) })
        default:
            return false
        }
    }

    /// The ascId of the row/offer/schedule a create payload produced, when it is visible in `live`.
    public static func createdAscId(_ payload: WritePayload, live: CellState, today: CalendarDate) -> String? {
        switch (payload, live) {
        case let (.createRegularPrice(p), .regular(current, scheduled)):
            return [current, scheduled].compactMap { $0 }.first { regularMatches(p, $0, today) }?.ascId
        case let (.createIntro(o), .intro(current, future)):
            return [current, future].compactMap { $0 }.first { introMatches(o, $0, today) }?.ascId
        case let (.createPromo(o), .promo(offer)):
            return offer?.offerCode == o.offerCode ? offer?.ascId : nil
        case (.replaceIAPSchedule, .iapSchedule(let schedule)):
            return schedule?.scheduleId
        default:
            return nil
        }
    }

    /// Target reached by a stored item: promo and IAP cells by the spike-confirmed semantics (TargetMatching, M4),
    /// every other cell by its natural key (isSatisfied).
    public static func reached(_ item: PlannedItem, live: CellState, today: CalendarDate) -> Bool {
        TargetMatching.promoOrIAPTargetReached(item, live: live, today: today)
            ?? isSatisfied(item.payload, live: live, today: today)
    }

    public static func resolve(_ item: PlannedItem, live: CellState, today: CalendarDate) -> Resolution {
        if reached(item, live: live, today: today) {
            return .targetFound(ascId: createdAscId(item.payload, live: live, today: today))
        }
        return matches(live: live, expected: item.before, today: today) ? .unchanged : .diverged
    }

    /// Replaces pending ids ("" or nil) in an expected state with the id ASC returned.
    public static func fillCreated(_ state: CellState, ascId: String?) -> CellState {
        guard let ascId, !ascId.isEmpty else { return state }
        func fill(_ row: RegularPriceRow?) -> RegularPriceRow? {
            guard var row, row.ascId.isEmpty else { return row }
            row.ascId = ascId
            return row
        }
        func fill(_ row: IntroOfferRow?) -> IntroOfferRow? {
            guard var row, row.ascId.isEmpty else { return row }
            row.ascId = ascId
            return row
        }
        switch state {
        case let .regular(current, scheduled):
            return .regular(current: fill(current), scheduled: fill(scheduled))
        case let .intro(current, future):
            return .intro(current: fill(current), future: fill(future))
        case let .promo(offer):
            guard var offer, offer.ascId.isEmpty else { return state }
            offer.ascId = ascId
            return .promo(offer)
        case let .iapSchedule(schedule):
            guard var schedule, schedule.scheduleId == nil else { return state }
            schedule.scheduleId = ascId
            return .iapSchedule(schedule)
        }
    }
}
