import Foundation
import Domain
import Catalog

public struct IAPScheduleDiffRow: Hashable, Sendable, Identifiable {
    public enum Change: String, Hashable, Sendable { case added, removed, changed, unchanged }

    public var territory: TerritoryCode
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public var before: Decimal?
    public var after: Decimal?
    public var change: Change
    public var deltaPercent: Decimal?
    public var id: String { "\(territory.rawValue)|\(startDate?.iso ?? "-")" }

    public init(territory: TerritoryCode, startDate: CalendarDate?, endDate: CalendarDate?, before: Decimal?, after: Decimal?,
                change: Change, deltaPercent: Decimal?) {
        self.territory = territory; self.startDate = startDate; self.endDate = endDate; self.before = before
        self.after = after; self.change = change; self.deltaPercent = deltaPercent
    }
}

/// Rule L1 display: the whole schedule before and after; rule L2: territories priced by Apple from the base.
public struct IAPScheduleDiff: Hashable, Sendable {
    public var baseBefore: TerritoryCode?
    public var baseAfter: TerritoryCode
    public var rows: [IAPScheduleDiffRow]
    public var autoPricedTerritories: [TerritoryCode]

    struct Key: Hashable, Comparable {
        let territory: TerritoryCode
        let start: CalendarDate?
        static func < (l: Key, r: Key) -> Bool {
            (l.territory.rawValue, l.start?.iso ?? "") < (r.territory.rawValue, r.start?.iso ?? "")
        }
    }

    public static func make(before: IAPSchedule?, after: NewIAPSchedule, pricePoints: PricePointIndex,
                            allTerritories: Set<TerritoryCode>, today: CalendarDate) -> IAPScheduleDiff {
        func key(_ territory: TerritoryCode, _ start: CalendarDate?) -> Key {
            Key(territory: territory, start: start.flatMap { $0 > today ? $0 : nil })
        }
        var beforeByKey: [Key: (price: Decimal, end: CalendarDate?)] = [:]
        for price in before?.manualPrices ?? [] where price.endDate.map({ $0 > today }) ?? true {
            beforeByKey[key(price.territory, price.startDate)] = (price.customerPrice, price.endDate)
        }
        var afterByKey: [Key: (price: Decimal?, end: CalendarDate?)] = [:]
        for price in after.manualPrices where price.endDate.map({ $0 > today }) ?? true {
            afterByKey[key(price.territory, price.startDate)] = (pricePoints.point(id: price.pricePointId)?.customerPrice, price.endDate)
        }
        let keys = Set(beforeByKey.keys).union(afterByKey.keys).sorted()
        let rows = keys.map { k -> IAPScheduleDiffRow in
            let old = beforeByKey[k]
            let new = afterByKey[k]
            let change: IAPScheduleDiffRow.Change
            switch (old, new) {
            case (nil, _): change = .added
            case (_, nil): change = .removed
            case let (o?, n?): change = o.price == n.price ? .unchanged : .changed
            }
            return IAPScheduleDiffRow(territory: k.territory, startDate: k.start, endDate: new?.end ?? old?.end,
                                      before: old?.price, after: new?.price, change: change,
                                      deltaPercent: percent(old?.price, new?.price))
        }
        let manualAfter = Set(afterByKey.keys.map(\.territory))
        return IAPScheduleDiff(baseBefore: before?.baseTerritory, baseAfter: after.baseTerritory, rows: rows,
                               autoPricedTerritories: allTerritories.subtracting(manualAfter).sorted())
    }

    static func percent(_ before: Decimal?, _ after: Decimal?) -> Decimal? {
        guard let before, let after, before != 0 else { return nil }
        var raw = (after - before) / before * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 1, .plain)
        return rounded
    }
}
