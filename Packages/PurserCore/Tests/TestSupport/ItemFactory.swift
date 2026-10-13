import Foundation
import Domain
import Catalog

/// Builds PlannedItems the way the planner does, for policy tests.
public enum ItemFactory {
    public static let planned = ""

    public static func regularPost(_ seq: Int, _ snapshot: CatalogSnapshot, sub: String, territory: TerritoryCode, price: Decimal,
                                   start: CalendarDate?, preserve: Bool, planType: PlanType = .upfront,
                                   afterDelete: Bool = false, dependsOn: [Int] = []) -> PlannedItem {
        let today = SyntheticCatalog.today
        let cell: CellKey = .regular(subscriptionId: sub, territory: territory, planType: planType)
        let current = snapshot.currentRegular(subscriptionId: sub, territory: territory, planType: planType, on: today)
        let scheduled = afterDelete ? nil : snapshot.scheduledRegular(subscriptionId: sub, territory: territory, planType: planType, on: today)
        let pointId = SyntheticCatalog.pointId(sub, territory, planType, price)
        let row = RegularPriceRow(ascId: planned, subscriptionId: sub, territory: territory, planType: planType, rawPlanType: planType.rawValue,
                                  startDate: start, preserved: false, pricePointId: pointId, customerPrice: price)
        let target: CellState = start == nil ? .regular(current: row, scheduled: nil) : .regular(current: current, scheduled: row)
        return PlannedItem(seq: seq, cell: cell,
                           payload: .createRegularPrice(NewRegularPrice(subscriptionId: sub, territory: territory, planType: planType,
                                                                        pricePointId: pointId, startDate: start, preserveCurrentPrice: preserve)),
                           before: .regular(current: current, scheduled: scheduled), target: target, dependsOn: dependsOn)
    }

    public static func regularDelete(_ seq: Int, _ snapshot: CatalogSnapshot, sub: String, territory: TerritoryCode) -> PlannedItem {
        let today = SyntheticCatalog.today
        let current = snapshot.currentRegular(subscriptionId: sub, territory: territory, planType: .upfront, on: today)
        let scheduled = snapshot.scheduledRegular(subscriptionId: sub, territory: territory, planType: .upfront, on: today)!
        return PlannedItem(seq: seq, cell: .regular(subscriptionId: sub, territory: territory, planType: .upfront),
                           payload: .deleteRegularPrice(ascId: scheduled.ascId),
                           before: .regular(current: current, scheduled: scheduled), target: .regular(current: current, scheduled: nil))
    }

    public static func introPost(_ seq: Int, before: CellState, sub: String, territory: TerritoryCode, mode: OfferMode = .payUpFront,
                                 duration: OfferDuration = .oneYear, periods: Int = 1, price: Decimal?, start: CalendarDate?,
                                 end: CalendarDate? = nil, dependsOn: [Int] = []) -> PlannedItem {
        let pointId = price.map { SyntheticCatalog.pointId(sub, territory, .upfront, $0) }
        let row = IntroOfferRow(ascId: planned, subscriptionId: sub, territory: territory, planType: .upfront, rawPlanType: "UPFRONT",
                                mode: mode, duration: duration, numberOfPeriods: periods, startDate: start, endDate: end,
                                pricePointId: pointId, customerPrice: price)
        guard case let .intro(current, future) = before else { fatalError("intro before expected") }
        let target: CellState = (start.map { $0 > SyntheticCatalog.today } ?? false)
            ? .intro(current: current, future: row) : .intro(current: row, future: future)
        return PlannedItem(seq: seq, cell: .intro(subscriptionId: sub, territory: territory, planType: .upfront),
                           payload: .createIntro(NewIntroOffer(subscriptionId: sub, territory: territory, planType: .upfront, mode: mode,
                                                               duration: duration, numberOfPeriods: periods, startDate: start,
                                                               endDate: end, pricePointId: pointId)),
                           before: before, target: target, dependsOn: dependsOn)
    }

    public static func introEnd(_ seq: Int, _ snapshot: CatalogSnapshot, sub: String, territory: TerritoryCode, at end: CalendarDate) -> PlannedItem {
        let state = snapshot.cellState(.intro(subscriptionId: sub, territory: territory, planType: .upfront), on: SyntheticCatalog.today)
        guard case let .intro(current?, future) = state else { fatalError("current intro expected") }
        var ended = current
        ended.endDate = end
        return PlannedItem(seq: seq, cell: .intro(subscriptionId: sub, territory: territory, planType: .upfront),
                           payload: .endIntro(ascId: current.ascId, endDate: end), before: state, target: .intro(current: ended, future: future))
    }

    public static func introDelete(_ seq: Int, _ snapshot: CatalogSnapshot, sub: String, territory: TerritoryCode) -> PlannedItem {
        let state = snapshot.cellState(.intro(subscriptionId: sub, territory: territory, planType: .upfront), on: SyntheticCatalog.today)
        guard case let .intro(current?, future) = state else { fatalError("current intro expected") }
        return PlannedItem(seq: seq, cell: .intro(subscriptionId: sub, territory: territory, planType: .upfront),
                           payload: .deleteIntro(ascId: current.ascId), before: state, target: .intro(current: nil, future: future))
    }
}
