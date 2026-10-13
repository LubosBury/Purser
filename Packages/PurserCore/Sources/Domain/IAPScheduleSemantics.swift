import Foundation

/// IAP price schedule semantics (rule L1; spike S10).
public enum IAPScheduleSemantics {
    struct Key: Hashable {
        let territory: TerritoryCode
        let pricePointId: String
        let start: CalendarDate?
    }

    /// A start on or before `today` counts as "already current" (nil): ASC may echo the creation day.
    static func effectiveStart(_ start: CalendarDate?, today: CalendarDate) -> CalendarDate? {
        guard let start, start > today else { return nil }
        return start
    }

    static func isRelevant(_ endDate: CalendarDate?, today: CalendarDate) -> Bool {
        endDate.map { $0 > today } ?? true
    }

    /// True when the live schedule equals the target: same base territory and the same set of
    /// (territory, price point, effective start) among prices that have not ended by `today`.
    /// An end date is compared only where the target sets one (ASC may close a price when a later one starts).
    public static func matches(live: IAPSchedule?, target: NewIAPSchedule, today: CalendarDate) -> Bool {
        guard let live, live.iapId == target.iapId, live.baseTerritory == target.baseTerritory else { return false }
        let liveRelevant = live.manualPrices.filter { isRelevant($0.endDate, today: today) }
        let targetRelevant = target.manualPrices.filter { isRelevant($0.endDate, today: today) }
        let liveKeys = Set(liveRelevant.map {
            Key(territory: $0.territory, pricePointId: $0.pricePointId, start: effectiveStart($0.startDate, today: today))
        })
        let targetKeys = Set(targetRelevant.map {
            Key(territory: $0.territory, pricePointId: $0.pricePointId, start: effectiveStart($0.startDate, today: today))
        })
        guard liveKeys == targetKeys else { return false }
        for wanted in targetRelevant where wanted.endDate != nil {
            let found = liveRelevant.contains {
                $0.territory == wanted.territory && $0.pricePointId == wanted.pricePointId && $0.endDate == wanted.endDate
            }
            if !found { return false }
        }
        return true
    }

    /// The schedule ASC holds after a whole-schedule POST (L1). Used by fakes; production reads it back.
    public static func afterReplace(_ target: NewIAPSchedule, scheduleId: String,
                                    customerPrice: (String) -> Decimal?) -> IAPSchedule {
        var n = 0
        let prices = target.manualPrices.map { price -> IAPManualPrice in
            n += 1
            return IAPManualPrice(ascId: "\(scheduleId)-price-\(n)", territory: price.territory,
                                  pricePointId: price.pricePointId, startDate: price.startDate,
                                  endDate: price.endDate, customerPrice: customerPrice(price.pricePointId) ?? 0)
        }
        return IAPSchedule(iapId: target.iapId, scheduleId: scheduleId, baseTerritory: target.baseTerritory, manualPrices: prices)
    }
}
