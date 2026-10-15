import Foundation

public struct SubscriptionInfo: Hashable, Sendable, Codable {
    public var ascId: String
    public var productId: String
    public var name: String
    public var period: SubscriptionPeriod
    public var state: ProductState
    public var groupId: String
    public var groupName: String
    public var availableTerritories: Set<TerritoryCode>
    public var monthlyPlanAvailable: Bool
    /// Copied by a clone. nil in a catalog stored before cloning existed (decoded with decodeIfPresent, as every
    /// Optional of a synthesized Codable) or when ASC leaves the attribute out.
    public var familySharable: Bool?
    public var reviewNote: String?
    public var groupLevel: Int?

    public init(ascId: String, productId: String, name: String, period: SubscriptionPeriod, state: ProductState,
                groupId: String, groupName: String, availableTerritories: Set<TerritoryCode>, monthlyPlanAvailable: Bool,
                familySharable: Bool? = nil, reviewNote: String? = nil, groupLevel: Int? = nil) {
        self.ascId = ascId; self.productId = productId; self.name = name; self.period = period; self.state = state
        self.groupId = groupId; self.groupName = groupName
        self.availableTerritories = availableTerritories; self.monthlyPlanAvailable = monthlyPlanAvailable
        self.familySharable = familySharable; self.reviewNote = reviewNote; self.groupLevel = groupLevel
    }
}

public struct IAPInfo: Hashable, Sendable, Codable {
    public var ascId: String
    public var productId: String
    public var name: String
    public var iapType: String
    public var state: ProductState
    /// Copied by a clone; nil in a catalog stored before cloning existed.
    public var familySharable: Bool?
    public var reviewNote: String?

    public init(ascId: String, productId: String, name: String, iapType: String, state: ProductState,
                familySharable: Bool? = nil, reviewNote: String? = nil) {
        self.ascId = ascId; self.productId = productId; self.name = name; self.iapType = iapType; self.state = state
        self.familySharable = familySharable; self.reviewNote = reviewNote
    }
}

public struct PricePoint: Hashable, Sendable, Codable {
    public var id: String
    public var productAscId: String
    public var territory: TerritoryCode
    public var planType: PlanType?
    public var customerPrice: Decimal
    public var proceeds: Decimal?

    public init(id: String, productAscId: String, territory: TerritoryCode, planType: PlanType?, customerPrice: Decimal, proceeds: Decimal?) {
        self.id = id; self.productAscId = productAscId; self.territory = territory
        self.planType = planType; self.customerPrice = customerPrice; self.proceeds = proceeds
    }
}

public struct RegularPriceRow: Hashable, Sendable, Codable {
    public var ascId: String
    public var subscriptionId: String
    public var territory: TerritoryCode
    public var planType: PlanType          // canonical, see PlanTypeCanonicalizer
    public var rawPlanType: String?        // exactly as ASC returned it; nil when absent
    public var startDate: CalendarDate?
    public var preserved: Bool
    public var pricePointId: String
    public var customerPrice: Decimal

    public init(ascId: String, subscriptionId: String, territory: TerritoryCode, planType: PlanType, rawPlanType: String?,
                startDate: CalendarDate?, preserved: Bool, pricePointId: String, customerPrice: Decimal) {
        self.ascId = ascId; self.subscriptionId = subscriptionId; self.territory = territory; self.planType = planType
        self.rawPlanType = rawPlanType; self.startDate = startDate; self.preserved = preserved
        self.pricePointId = pricePointId; self.customerPrice = customerPrice
    }
}

public struct IntroOfferRow: Hashable, Sendable, Codable {
    public var ascId: String
    public var subscriptionId: String
    public var territory: TerritoryCode
    public var planType: PlanType          // canonical targetSubscriptionPlanType
    public var rawPlanType: String?
    public var mode: OfferMode
    public var duration: OfferDuration
    public var numberOfPeriods: Int
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public var pricePointId: String?
    public var customerPrice: Decimal?

    public init(ascId: String, subscriptionId: String, territory: TerritoryCode, planType: PlanType, rawPlanType: String?,
                mode: OfferMode, duration: OfferDuration, numberOfPeriods: Int, startDate: CalendarDate?, endDate: CalendarDate?,
                pricePointId: String?, customerPrice: Decimal?) {
        self.ascId = ascId; self.subscriptionId = subscriptionId; self.territory = territory; self.planType = planType
        self.rawPlanType = rawPlanType; self.mode = mode; self.duration = duration; self.numberOfPeriods = numberOfPeriods
        self.startDate = startDate; self.endDate = endDate; self.pricePointId = pricePointId; self.customerPrice = customerPrice
    }

    /// Active on `day`: startDate <= day (or nil) and day < endDate (or nil).
    public func isActive(on day: CalendarDate) -> Bool {
        (startDate.map { $0 <= day } ?? true) && (endDate.map { day < $0 } ?? true)
    }
}

public struct PromoPrice: Hashable, Sendable, Codable {
    public var ascId: String?
    public var territory: TerritoryCode
    public var pricePointId: String?
    public var customerPrice: Decimal?

    public init(ascId: String?, territory: TerritoryCode, pricePointId: String?, customerPrice: Decimal?) {
        self.ascId = ascId; self.territory = territory; self.pricePointId = pricePointId; self.customerPrice = customerPrice
    }
}

public struct PromoOffer: Hashable, Sendable, Codable {
    public var ascId: String
    public var subscriptionId: String
    public var offerCode: String
    public var name: String
    public var mode: OfferMode
    public var duration: OfferDuration
    public var numberOfPeriods: Int
    public var planType: PlanType
    public var prices: [PromoPrice]        // sorted by territory

    public init(ascId: String, subscriptionId: String, offerCode: String, name: String, mode: OfferMode,
                duration: OfferDuration, numberOfPeriods: Int, planType: PlanType, prices: [PromoPrice]) {
        self.ascId = ascId; self.subscriptionId = subscriptionId; self.offerCode = offerCode; self.name = name
        self.mode = mode; self.duration = duration; self.numberOfPeriods = numberOfPeriods; self.planType = planType
        self.prices = prices.sorted { $0.territory < $1.territory }
    }
}

public struct IAPManualPrice: Hashable, Sendable, Codable {
    public var ascId: String?
    public var territory: TerritoryCode
    public var pricePointId: String
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public var customerPrice: Decimal

    public init(ascId: String?, territory: TerritoryCode, pricePointId: String, startDate: CalendarDate?, endDate: CalendarDate?, customerPrice: Decimal) {
        self.ascId = ascId; self.territory = territory; self.pricePointId = pricePointId
        self.startDate = startDate; self.endDate = endDate; self.customerPrice = customerPrice
    }
}

public struct IAPSchedule: Hashable, Sendable, Codable {
    public var iapId: String
    public var scheduleId: String?
    public var baseTerritory: TerritoryCode
    public var manualPrices: [IAPManualPrice]  // sorted by territory, then startDate

    public init(iapId: String, scheduleId: String?, baseTerritory: TerritoryCode, manualPrices: [IAPManualPrice]) {
        self.iapId = iapId; self.scheduleId = scheduleId; self.baseTerritory = baseTerritory
        self.manualPrices = manualPrices.sorted {
            ($0.territory.rawValue, $0.startDate?.iso ?? "") < ($1.territory.rawValue, $1.startDate?.iso ?? "")
        }
    }
}

public enum PlanTypeCanonicalizer {
    /// Spec §5: a missing plan type means UPFRONT on a subscription without MONTHLY availability.
    /// Returns nil when the value is missing and the subscription offers MONTHLY (ambiguous; surfaced as a finding).
    public static func canonical(raw: String?, monthlyPlanAvailable: Bool) -> PlanType? {
        if let raw, let p = PlanType(rawValue: raw) { return p }
        return monthlyPlanAvailable ? nil : .upfront
    }
}
