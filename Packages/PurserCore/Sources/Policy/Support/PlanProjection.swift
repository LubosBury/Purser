import Foundation
import Domain
import Catalog

/// The catalog as it will look after the plan: for every touched cell the target of its last item (highest seq),
/// for every other cell the snapshot state on `today`.
struct PlanProjection {
    let snapshot: CatalogSnapshot
    let today: CalendarDate
    let finalStates: [CellKey: CellState]

    init(snapshot: CatalogSnapshot, items: [PlannedItem], today: CalendarDate) {
        self.snapshot = snapshot
        self.today = today
        var latest: [CellKey: PlannedItem] = [:]
        for item in items where (latest[item.cell]?.seq ?? Int.min) < item.seq { latest[item.cell] = item }
        finalStates = latest.mapValues(\.target)
    }

    func state(_ cell: CellKey) -> CellState { finalStates[cell] ?? snapshot.cellState(cell, on: today) }

    func regular(_ sub: String, _ territory: TerritoryCode, _ planType: PlanType) -> (current: RegularPriceRow?, scheduled: RegularPriceRow?) {
        if case let .regular(c, s) = state(.regular(subscriptionId: sub, territory: territory, planType: planType)) { return (c, s) }
        return (nil, nil)
    }

    func regularPrice(_ sub: String, _ territory: TerritoryCode, _ planType: PlanType, on day: CalendarDate) -> Decimal? {
        let r = regular(sub, territory, planType)
        if let s = r.scheduled, let start = s.startDate, start <= day { return s.customerPrice }
        return r.current?.customerPrice
    }

    /// Every regular price that applies on some day of [from, to): the price on `from` plus the scheduled change inside.
    func regularPrices(_ sub: String, _ territory: TerritoryCode, _ planType: PlanType,
                       from: CalendarDate, to: CalendarDate?) -> [(day: CalendarDate, price: Decimal)] {
        var result: [(day: CalendarDate, price: Decimal)] = []
        if let price = regularPrice(sub, territory, planType, on: from) { result.append((from, price)) }
        if let s = regular(sub, territory, planType).scheduled, let start = s.startDate, start > from, to.map({ start < $0 }) ?? true {
            result.append((start, s.customerPrice))
        }
        return result
    }

    func introRows(_ sub: String, _ territory: TerritoryCode, _ planType: PlanType) -> [IntroOfferRow] {
        if case let .intro(c, f) = state(.intro(subscriptionId: sub, territory: territory, planType: planType)) { return [c, f].compactMap { $0 } }
        return []
    }

    func promoOffers(subscriptionId: String) -> [PromoOffer] {
        var offers = snapshot.promoOffers(subscriptionId: subscriptionId)
        for (cell, state) in finalStates {
            guard case let .promo(sub, code) = cell, sub == subscriptionId, case let .promo(offer) = state else { continue }
            offers.removeAll { $0.offerCode == code }
            if let offer { offers.append(offer) }
        }
        return offers.sorted { $0.offerCode < $1.offerCode }
    }

    /// (subscription, territory, planType) triples touched by regular or intro items.
    var touchedPriceCells: Set<PriceCell> {
        Set(finalStates.keys.compactMap { cell in
            switch cell {
            case let .regular(s, t, p), let .intro(s, t, p): return PriceCell(subscriptionId: s, territory: t, planType: p)
            default: return nil
            }
        })
    }
}

struct PriceCell: Hashable, Comparable {
    var subscriptionId: String
    var territory: TerritoryCode
    var planType: PlanType

    var regularCell: CellKey { .regular(subscriptionId: subscriptionId, territory: territory, planType: planType) }
    var introCell: CellKey { .intro(subscriptionId: subscriptionId, territory: territory, planType: planType) }

    static func < (l: Self, r: Self) -> Bool {
        (l.subscriptionId, l.territory.rawValue, l.planType.rawValue) < (r.subscriptionId, r.territory.rawValue, r.planType.rawValue)
    }
}

/// Remaining validity of an intro row: [max(start, today), end); nil when it is already over.
struct IntroWindow {
    let from: CalendarDate
    let to: CalendarDate?

    init?(row: IntroOfferRow, today: CalendarDate) {
        let start = max(row.startDate ?? today, today)
        if let end = row.endDate, end <= start { return nil }
        from = start
        to = row.endDate
    }
}
