import Foundation
import Domain

public struct FakeApp: Hashable, Sendable {
    public var id: String
    public var bundleId: String
    public var name: String
    public init(id: String, bundleId: String, name: String) { self.id = id; self.bundleId = bundleId; self.name = name }
}

public struct FakeGroup: Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct FakeSubscription: Hashable, Sendable {
    public var id: String
    public var productId: String
    public var name: String
    public var period: SubscriptionPeriod
    public var state: ProductState
    public var groupId: String
    public var availableTerritories: Set<TerritoryCode>
    public init(id: String, productId: String, name: String, period: SubscriptionPeriod, state: ProductState,
                groupId: String, availableTerritories: Set<TerritoryCode>) {
        self.id = id; self.productId = productId; self.name = name; self.period = period; self.state = state
        self.groupId = groupId; self.availableTerritories = availableTerritories
    }
}

public struct FakePricePoint: Hashable, Sendable {
    public var id: String
    public var productId: String          // subscription or IAP asc id
    public var territory: TerritoryCode
    public var planType: PlanType?        // nil for IAP points
    public var customerPrice: Decimal
    public var proceeds: Decimal
    public init(id: String, productId: String, territory: TerritoryCode, planType: PlanType?, customerPrice: Decimal, proceeds: Decimal) {
        self.id = id; self.productId = productId; self.territory = territory; self.planType = planType
        self.customerPrice = customerPrice; self.proceeds = proceeds
    }
}

public struct FakeRegularPrice: Hashable, Sendable {
    public var id: String
    public var subscriptionId: String
    public var territory: TerritoryCode
    public var planType: PlanType
    public var sendsPlanType: Bool        // false: reads omit planType (S0/S2 variant)
    public var startDate: CalendarDate?
    public var preserved: Bool
    public var pricePointId: String
    public init(id: String, subscriptionId: String, territory: TerritoryCode, planType: PlanType, sendsPlanType: Bool,
                startDate: CalendarDate?, preserved: Bool, pricePointId: String) {
        self.id = id; self.subscriptionId = subscriptionId; self.territory = territory; self.planType = planType
        self.sendsPlanType = sendsPlanType; self.startDate = startDate; self.preserved = preserved; self.pricePointId = pricePointId
    }
}

public struct FakeIntro: Hashable, Sendable {
    public var id: String
    public var subscriptionId: String
    public var territory: TerritoryCode
    public var planType: PlanType
    public var mode: OfferMode
    public var duration: OfferDuration
    public var numberOfPeriods: Int
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public var pricePointId: String?
    public var createdOn: CalendarDate
    public init(id: String, subscriptionId: String, territory: TerritoryCode, planType: PlanType, mode: OfferMode,
                duration: OfferDuration, numberOfPeriods: Int, startDate: CalendarDate?, endDate: CalendarDate?,
                pricePointId: String?, createdOn: CalendarDate) {
        self.id = id; self.subscriptionId = subscriptionId; self.territory = territory; self.planType = planType
        self.mode = mode; self.duration = duration; self.numberOfPeriods = numberOfPeriods; self.startDate = startDate
        self.endDate = endDate; self.pricePointId = pricePointId; self.createdOn = createdOn
    }
    /// A null startDate means "the day the offer was created".
    public var effectiveStart: CalendarDate { startDate ?? createdOn }
}

public struct FakePromoPrice: Hashable, Sendable {
    public var id: String
    public var territory: TerritoryCode
    public var pricePointId: String?
    public init(id: String, territory: TerritoryCode, pricePointId: String?) { self.id = id; self.territory = territory; self.pricePointId = pricePointId }
}

public struct FakePromo: Hashable, Sendable {
    public var id: String
    public var subscriptionId: String
    public var offerCode: String
    public var name: String
    public var mode: OfferMode
    public var duration: OfferDuration
    public var numberOfPeriods: Int
    public var planType: PlanType
    public var prices: [FakePromoPrice]
    public init(id: String, subscriptionId: String, offerCode: String, name: String, mode: OfferMode, duration: OfferDuration,
                numberOfPeriods: Int, planType: PlanType, prices: [FakePromoPrice]) {
        self.id = id; self.subscriptionId = subscriptionId; self.offerCode = offerCode; self.name = name; self.mode = mode
        self.duration = duration; self.numberOfPeriods = numberOfPeriods; self.planType = planType; self.prices = prices
    }
}

public struct FakeIAP: Hashable, Sendable {
    public var id: String
    public var productId: String
    public var name: String
    public var type: String
    public var state: ProductState
    public init(id: String, productId: String, name: String, type: String, state: ProductState) {
        self.id = id; self.productId = productId; self.name = name; self.type = type; self.state = state
    }
}

public struct FakeIAPManualPrice: Hashable, Sendable {
    public var id: String
    public var territory: TerritoryCode
    public var pricePointId: String
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public init(id: String, territory: TerritoryCode, pricePointId: String, startDate: CalendarDate?, endDate: CalendarDate?) {
        self.id = id; self.territory = territory; self.pricePointId = pricePointId; self.startDate = startDate; self.endDate = endDate
    }
}

public struct FakeIAPSchedule: Hashable, Sendable {
    public var id: String
    public var iapId: String
    public var baseTerritory: TerritoryCode
    public var manualPrices: [FakeIAPManualPrice]
    public init(id: String, iapId: String, baseTerritory: TerritoryCode, manualPrices: [FakeIAPManualPrice]) {
        self.id = id; self.iapId = iapId; self.baseTerritory = baseTerritory; self.manualPrices = manualPrices
    }
}

public struct FakeModel: Sendable {
    public var app: FakeApp
    public var territories: [TerritoryCode: CurrencyCode]
    public var groups: [FakeGroup]
    public var subscriptions: [FakeSubscription]
    public var pricePoints: [FakePricePoint]
    public var regularPrices: [FakeRegularPrice]
    public var intros: [FakeIntro]
    public var promos: [FakePromo]
    public var usedOfferCodes: Set<String>
    public var iaps: [FakeIAP]
    public var iapSchedules: [FakeIAPSchedule]

    public init(app: FakeApp, territories: [TerritoryCode: CurrencyCode], groups: [FakeGroup], subscriptions: [FakeSubscription],
                pricePoints: [FakePricePoint], regularPrices: [FakeRegularPrice], intros: [FakeIntro], promos: [FakePromo],
                usedOfferCodes: Set<String>, iaps: [FakeIAP], iapSchedules: [FakeIAPSchedule]) {
        self.app = app; self.territories = territories; self.groups = groups; self.subscriptions = subscriptions
        self.pricePoints = pricePoints; self.regularPrices = regularPrices; self.intros = intros; self.promos = promos
        self.usedOfferCodes = usedOfferCodes; self.iaps = iaps; self.iapSchedules = iapSchedules
    }
}
