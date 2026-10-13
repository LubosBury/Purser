import Foundation
import Domain
import Catalog

/// Test-side mirror of what the Planner puts into `target`: rows created by the item get ascId "" (K9 placeholder).
public enum TargetBuilder {
    public static func apply(_ payload: WritePayload, to state: CellState, points: PricePointIndex, today: CalendarDate) -> CellState {
        switch (payload, state) {
        case let (.createRegularPrice(p), .regular(current, scheduled)):
            let row = RegularPriceRow(ascId: "", subscriptionId: p.subscriptionId, territory: p.territory, planType: p.planType,
                                      rawPlanType: p.planType.rawValue, startDate: p.startDate, preserved: p.preserveCurrentPrice,
                                      pricePointId: p.pricePointId, customerPrice: points.point(id: p.pricePointId)?.customerPrice ?? 0)
            if let start = p.startDate, start > today { return .regular(current: current, scheduled: row) }
            return .regular(current: row, scheduled: scheduled)
        case let (.deleteRegularPrice(id), .regular(current, scheduled)):
            return .regular(current: current?.ascId == id ? nil : current, scheduled: scheduled?.ascId == id ? nil : scheduled)
        case let (.createIntro(o), .intro(current, future)):
            let row = IntroOfferRow(ascId: "", subscriptionId: o.subscriptionId, territory: o.territory, planType: o.planType,
                                    rawPlanType: o.planType.rawValue, mode: o.mode, duration: o.duration, numberOfPeriods: o.numberOfPeriods,
                                    startDate: o.startDate, endDate: o.endDate, pricePointId: o.pricePointId,
                                    customerPrice: o.pricePointId.flatMap { points.point(id: $0)?.customerPrice })
            if let start = o.startDate, start > today { return .intro(current: current, future: row) }
            return .intro(current: row, future: future)
        case let (.endIntro(id, end), .intro(current, future)):
            func ended(_ row: IntroOfferRow?) -> IntroOfferRow? {
                guard var row, row.ascId == id else { return row }
                row.endDate = end
                return row
            }
            return .intro(current: ended(current), future: ended(future))
        case let (.deleteIntro(id), .intro(current, future)):
            return .intro(current: current?.ascId == id ? nil : current, future: future?.ascId == id ? nil : future)
        case let (.createPromo(o), .promo):
            return .promo(PromoOffer(ascId: "", subscriptionId: o.subscriptionId, offerCode: o.offerCode, name: o.name, mode: o.mode,
                                     duration: o.duration, numberOfPeriods: o.numberOfPeriods, planType: o.planType,
                                     prices: o.prices.map { PromoPrice(ascId: nil, territory: $0.territory, pricePointId: $0.pricePointId, customerPrice: nil) }))
        case let (.replacePromoPrices(_, prices), .promo(offer?)):
            var updated = offer
            updated.prices = prices.map { PromoPrice(ascId: nil, territory: $0.territory, pricePointId: $0.pricePointId, customerPrice: nil) }
                .sorted { $0.territory < $1.territory }
            return .promo(updated)
        case (.deletePromo, .promo):
            return .promo(nil)
        case let (.replaceIAPSchedule(s), .iapSchedule):
            return .iapSchedule(IAPSchedule(iapId: s.iapId, scheduleId: nil, baseTerritory: s.baseTerritory, manualPrices: s.manualPrices.map {
                IAPManualPrice(ascId: nil, territory: $0.territory, pricePointId: $0.pricePointId, startDate: $0.startDate,
                               endDate: $0.endDate, customerPrice: points.point(id: $0.pricePointId)?.customerPrice ?? 0)
            }))
        default:
            return state
        }
    }
}

/// Executor chains on top of M1's ItemFactory (Tests/TestSupport/ItemFactory.swift, Task 1.7).
extension ItemFactory {
    /// One cell's chain: before(k) = target(k-1), dependsOn = previous seq (the first item gets `dependsOn`).
    public static func chain(cell: CellKey, payloads: [WritePayload], firstSeq: Int, snapshot: CatalogSnapshot,
                             today: CalendarDate, dependsOn: [Int] = []) -> [PlannedItem] {
        var state = snapshot.cellState(cell, on: today)
        var items: [PlannedItem] = []
        for (offset, payload) in payloads.enumerated() {
            let target = TargetBuilder.apply(payload, to: state, points: snapshot.pricePoints, today: today)
            let seq = firstSeq + offset
            items.append(PlannedItem(seq: seq, cell: cell, payload: payload, before: state, target: target,
                                     dependsOn: offset == 0 ? dependsOn : [seq - 1]))
            state = target
        }
        return items
    }
}
