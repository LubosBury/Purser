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
    public var familySharable: Bool
    public var reviewNote: String?
    /// nil: the listing reports the position in the group (1, 2, …) as before cloning existed.
    public var groupLevel: Int?
    public init(id: String, productId: String, name: String, period: SubscriptionPeriod, state: ProductState,
                groupId: String, availableTerritories: Set<TerritoryCode>, familySharable: Bool = false, reviewNote: String? = nil,
                groupLevel: Int? = nil) {
        self.id = id; self.productId = productId; self.name = name; self.period = period; self.state = state
        self.groupId = groupId; self.availableTerritories = availableTerritories
        self.familySharable = familySharable; self.reviewNote = reviewNote; self.groupLevel = groupLevel
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
    public var familySharable: Bool
    public var reviewNote: String?
    /// nil: the purchase has no availability yet (GET …/inAppPurchaseAvailability answers 404).
    public var availableTerritories: Set<TerritoryCode>?
    public init(id: String, productId: String, name: String, type: String, state: ProductState, familySharable: Bool = false,
                reviewNote: String? = nil, availableTerritories: Set<TerritoryCode>? = nil) {
        self.id = id; self.productId = productId; self.name = name; self.type = type; self.state = state
        self.familySharable = familySharable; self.reviewNote = reviewNote; self.availableTerritories = availableTerritories
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

/// A subscription, IAP or group version (ASC API 4.4.1).
public struct FakeVersion: Hashable, Sendable {
    public var id: String
    public var owner: LocalizationOwner
    public var number: Int
    public var state: MetadataVersionState
    public init(id: String, owner: LocalizationOwner, number: Int, state: MetadataVersionState) {
        self.id = id; self.owner = owner; self.number = number; self.state = state
    }
}

/// The texts of one locale in one version. The owner is the version's; a group's text uses `customAppName`, never `description`.
public struct FakeLocalization: Hashable, Sendable {
    public var id: String
    public var versionId: String
    public var locale: String
    public var text: LocalizationText
    public init(id: String, versionId: String, locale: String, text: LocalizationText) {
        self.id = id; self.versionId = versionId; self.locale = locale; self.text = text
    }
}

/// The App Store review screenshot of a subscription or an in-app purchase. `received` holds the uploaded bytes.
public struct FakeScreenshot: Hashable, Sendable {
    public var id: String
    public var owner: LocalizationOwner
    public var fileName: String
    public var fileSize: Int
    public var state: String                  // AWAITING_UPLOAD, UPLOAD_COMPLETE, COMPLETE, FAILED
    public var received: Data
    public var receivedParts: Set<Int>
    public var checksum: String?
    public var templateURL: String?
    public var width: Int?
    public var height: Int?
    public init(id: String, owner: LocalizationOwner, fileName: String, fileSize: Int, state: String, received: Data? = nil,
                receivedParts: Set<Int> = [], checksum: String? = nil, templateURL: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.id = id; self.owner = owner; self.fileName = fileName; self.fileSize = fileSize; self.state = state
        self.received = received ?? Data(count: fileSize); self.receivedParts = receivedParts; self.checksum = checksum
        self.templateURL = templateURL; self.width = width; self.height = height
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
    public var versions: [FakeVersion]
    public var localizations: [FakeLocalization]
    /// App Store review screenshots (cloning).
    public var screenshots: [FakeScreenshot] = []
    /// availableInNewTerritories of every availability a POST created or a seed set (product ASC id -> flag).
    public var availabilityInNew: [String: Bool] = [:]

    public init(app: FakeApp, territories: [TerritoryCode: CurrencyCode], groups: [FakeGroup], subscriptions: [FakeSubscription],
                pricePoints: [FakePricePoint], regularPrices: [FakeRegularPrice], intros: [FakeIntro], promos: [FakePromo],
                usedOfferCodes: Set<String>, iaps: [FakeIAP], iapSchedules: [FakeIAPSchedule],
                versions: [FakeVersion] = [], localizations: [FakeLocalization] = []) {
        self.app = app; self.territories = territories; self.groups = groups; self.subscriptions = subscriptions
        self.pricePoints = pricePoints; self.regularPrices = regularPrices; self.intros = intros; self.promos = promos
        self.usedOfferCodes = usedOfferCodes; self.iaps = iaps; self.iapSchedules = iapSchedules
        self.versions = versions; self.localizations = localizations
    }
}
