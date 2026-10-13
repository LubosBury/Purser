import Foundation
import Domain
import Catalog

enum RegularTimeline {
    /// Regular prices that apply on some day of [from, to) once `intent` (if any) replaces the cell's scheduled change.
    static func prices(_ snapshot: CatalogSnapshot, key: PriceKey, today: CalendarDate, intent: RegularIntent?,
                       from: CalendarDate, to: CalendarDate?) -> [Decimal] {
        var current = snapshot.currentRegular(subscriptionId: key.subscriptionId, territory: key.territory, planType: key.planType, on: today)?.customerPrice
        var scheduled: (day: CalendarDate, price: Decimal)? = snapshot.scheduledRegular(
            subscriptionId: key.subscriptionId, territory: key.territory, planType: key.planType, on: today)
            .flatMap { row in row.startDate.map { ($0, row.customerPrice) } }
        if let intent {
            if let start = intent.startDate, start > today {
                scheduled = (start, intent.point.customerPrice)
            } else {
                current = intent.point.customerPrice
                scheduled = nil
            }
        }
        var result: [Decimal] = []
        if let scheduled, scheduled.day <= from {
            result.append(scheduled.price)
        } else if let current {
            result.append(current)
        }
        if let scheduled, scheduled.day > from, to.map({ scheduled.day < $0 }) ?? true { result.append(scheduled.price) }
        return result
    }
}
