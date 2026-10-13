import Foundation
import Domain

/// Re-checks R4, R6 and I7 right before a request leaves (spec §6 step 4). A violation makes the item Stale.
package enum DeadlineCheck {
    package static func violation(_ item: PlannedItem, productState: ProductState?, now: Date) -> String? {
        let today = CalendarDate.today(now: now)
        let earliest = today.adding(days: AppleConstants.minLeadDays)
        let approved = productState == .approved
        switch item.payload {
        case let .createRegularPrice(p):
            if let start = p.startDate {
                if start < today { return "R4: startDate \(start) is in the past" }
                if approved, start < earliest { return "R4: startDate \(start) is before \(earliest)" }
            } else if case let .regular(current, scheduled) = item.before, current != nil || scheduled != nil {
                return "R4: startDate must not be null for a subscription that already has a price"
            }
        case let .createIntro(o):
            if approved, (o.startDate.map { $0 < earliest } ?? true) {
                return "R4: a new intro on an approved subscription must start on or after \(earliest)"
            }
        case let .endIntro(_, end):
            if approved, end < earliest { return "I7: endDate \(end) is before \(earliest)" }
        case let .deleteRegularPrice(id):
            if case let .regular(_, scheduled) = item.before, let row = scheduled, row.ascId == id, let start = row.startDate {
                let hoursLeft = start.startOfDayUTC.timeIntervalSince(now) / 3600
                if hoursLeft < Double(AppleConstants.replaceCutoffHours) {
                    return "R6: the scheduled change starts in \(Int(hoursLeft)) h, less than \(AppleConstants.replaceCutoffHours) h"
                }
            }
        default:
            break
        }
        return nil
    }
}
