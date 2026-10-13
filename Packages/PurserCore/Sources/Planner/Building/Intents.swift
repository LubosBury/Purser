import Foundation
import Domain
import Catalog

/// (subscription, territory, plan type): the shared key of a regular cell and its intro cell.
struct PriceKey: Hashable, Comparable {
    var subscriptionId: String
    var territory: TerritoryCode
    var planType: PlanType

    var regularCell: CellKey { .regular(subscriptionId: subscriptionId, territory: territory, planType: planType) }
    var introCell: CellKey { .intro(subscriptionId: subscriptionId, territory: territory, planType: planType) }

    static func < (l: Self, r: Self) -> Bool {
        (l.subscriptionId, l.territory.rawValue, l.planType.rawValue) < (r.subscriptionId, r.territory.rawValue, r.planType.rawValue)
    }
}

enum PriceDirection { case increase, decrease, initial }

/// Desired regular price of one cell.
struct RegularIntent {
    var key: PriceKey
    var point: PricePoint
    var startDate: CalendarDate?
    var preserve: Bool
    var direction: PriceDirection
}

/// Desired intro offer of one cell.
struct IntroIntent {
    var key: PriceKey
    var mode: OfferMode
    var duration: OfferDuration
    var periods: Int
    var startDate: CalendarDate?
    var endDate: CalendarDate?
    var point: PricePoint?
    var flags: [ItemFlag] = []
    var rules: [RuleID] = []
}
