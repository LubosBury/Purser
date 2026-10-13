import Foundation
import Domain

public struct CatalogSnapshot: Sendable {
    public let syncId: Int64
    public let takenAt: Date
    public let subscriptions: [String: SubscriptionInfo]
    public let iaps: [String: IAPInfo]
    public let territories: [TerritoryCode: CurrencyCode]
    public let regularRows: [RegularPriceRow]
    public let introRows: [IntroOfferRow]
    public let promoOffers: [PromoOffer]
    public let iapSchedules: [String: IAPSchedule]
    public let pricePoints: PricePointIndex
    public let offerCodesEverSeen: Set<String>

    private let regularByCell: [CellKey: [RegularPriceRow]]
    private let introByCell: [CellKey: [IntroOfferRow]]

    public init(syncId: Int64, takenAt: Date, subscriptions: [String: SubscriptionInfo], iaps: [String: IAPInfo],
                territories: [TerritoryCode: CurrencyCode], regularRows: [RegularPriceRow], introRows: [IntroOfferRow],
                promoOffers: [PromoOffer], iapSchedules: [String: IAPSchedule], pricePoints: PricePointIndex,
                offerCodesEverSeen: Set<String>) {
        self.syncId = syncId; self.takenAt = takenAt; self.subscriptions = subscriptions; self.iaps = iaps
        self.territories = territories; self.regularRows = regularRows; self.introRows = introRows
        self.promoOffers = promoOffers; self.iapSchedules = iapSchedules; self.pricePoints = pricePoints
        self.offerCodesEverSeen = offerCodesEverSeen
        regularByCell = Dictionary(grouping: regularRows) { .regular(subscriptionId: $0.subscriptionId, territory: $0.territory, planType: $0.planType) }
        introByCell = Dictionary(grouping: introRows) { .intro(subscriptionId: $0.subscriptionId, territory: $0.territory, planType: $0.planType) }
    }

    /// Current = latest startDate <= day (nil startDate counts as the oldest row).
    public func currentRegular(subscriptionId: String, territory: TerritoryCode, planType: PlanType, on day: CalendarDate) -> RegularPriceRow? {
        regularByCell[.regular(subscriptionId: subscriptionId, territory: territory, planType: planType)]?
            .filter { $0.startDate.map { $0 <= day } ?? true }
            .max { Self.regularOrder($0, $1) }
    }

    /// The single future change (startDate > day), if any.
    public func scheduledRegular(subscriptionId: String, territory: TerritoryCode, planType: PlanType, on day: CalendarDate) -> RegularPriceRow? {
        regularByCell[.regular(subscriptionId: subscriptionId, territory: territory, planType: planType)]?
            .filter { $0.startDate.map { $0 > day } ?? false }
            .min { Self.regularOrder($0, $1) }
    }

    public func currentIntro(subscriptionId: String, territory: TerritoryCode, planType: PlanType, on day: CalendarDate) -> IntroOfferRow? {
        introByCell[.intro(subscriptionId: subscriptionId, territory: territory, planType: planType)]?
            .filter { $0.isActive(on: day) }
            .max { ($0.startDate?.iso ?? "", $0.ascId) < ($1.startDate?.iso ?? "", $1.ascId) }
    }

    public func futureIntro(subscriptionId: String, territory: TerritoryCode, planType: PlanType, on day: CalendarDate) -> IntroOfferRow? {
        introByCell[.intro(subscriptionId: subscriptionId, territory: territory, planType: planType)]?
            .filter { $0.startDate.map { $0 > day } ?? false }
            .min { ($0.startDate?.iso ?? "", $0.ascId) < ($1.startDate?.iso ?? "", $1.ascId) }
    }

    public func promoOffers(subscriptionId: String) -> [PromoOffer] {
        promoOffers.filter { $0.subscriptionId == subscriptionId }.sorted { $0.offerCode < $1.offerCode }
    }

    public func cellState(_ cell: CellKey, on day: CalendarDate) -> CellState {
        switch cell {
        case let .regular(subscriptionId, territory, planType):
            return .regular(current: currentRegular(subscriptionId: subscriptionId, territory: territory, planType: planType, on: day),
                            scheduled: scheduledRegular(subscriptionId: subscriptionId, territory: territory, planType: planType, on: day))
        case let .intro(subscriptionId, territory, planType):
            return .intro(current: currentIntro(subscriptionId: subscriptionId, territory: territory, planType: planType, on: day),
                          future: futureIntro(subscriptionId: subscriptionId, territory: territory, planType: planType, on: day))
        case let .promo(subscriptionId, offerCode):
            return .promo(promoOffers.first { $0.subscriptionId == subscriptionId && $0.offerCode == offerCode })
        case let .iapSchedule(iapId):
            return .iapSchedule(iapSchedules[iapId])
        }
    }

    /// Regular price effective on `day` (current row on that day, taking the scheduled change into account).
    public func regularPrice(subscriptionId: String, territory: TerritoryCode, planType: PlanType, on day: CalendarDate) -> Decimal? {
        currentRegular(subscriptionId: subscriptionId, territory: territory, planType: planType, on: day)?.customerPrice
    }

    /// Orders by startDate (nil first); on the same date a preserved row sorts before the live one.
    private static func regularOrder(_ a: RegularPriceRow, _ b: RegularPriceRow) -> Bool {
        let left = (a.startDate?.iso ?? "", a.preserved ? 0 : 1, a.ascId)
        let right = (b.startDate?.iso ?? "", b.preserved ? 0 : 1, b.ascId)
        return left < right
    }
}
