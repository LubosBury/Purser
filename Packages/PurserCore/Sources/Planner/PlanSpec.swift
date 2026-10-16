import Foundation
import Domain
import Store
import Catalog
import Importer
import ASCClient

public struct PlanFilter: Hashable, Sendable, Codable {
    public var productAscIds: Set<String>?
    public var territories: Set<TerritoryCode>?
    public init(productAscIds: Set<String>? = nil, territories: Set<TerritoryCode>? = nil) {
        self.productAscIds = productAscIds; self.territories = territories
    }
    public func includes(product: String) -> Bool { productAscIds?.contains(product) ?? true }
    public func includes(territory: TerritoryCode) -> Bool { territories?.contains(territory) ?? true }
}

public struct TerritoryAmount: Hashable, Sendable, Codable {
    public var territory: TerritoryCode
    public var amount: Decimal
    public init(territory: TerritoryCode, amount: Decimal) { self.territory = territory; self.amount = amount }
}

public enum IntroPricing: Hashable, Sendable, Codable {
    case freeTrial
    case percentOfRegular(Decimal)                 // 0.80 = 80% of the regular price during the intro
    case table([TerritoryAmount])
    case trialLengths([TerritoryCode: OfferDuration])
}

public struct ImportPlanSpec: Hashable, Sendable, Codable {
    public var table: ImportedTable
    public var writeColumns: [String]
    public var filter: PlanFilter
    public var startDate: CalendarDate?
    public var preserveCurrentPrice: Bool?         // required (no default) when the plan contains increases (R1)
    public var canary: Bool
    public init(table: ImportedTable, writeColumns: [String], filter: PlanFilter, startDate: CalendarDate?,
                preserveCurrentPrice: Bool?, canary: Bool) {
        self.table = table; self.writeColumns = writeColumns; self.filter = filter; self.startDate = startDate
        self.preserveCurrentPrice = preserveCurrentPrice; self.canary = canary
    }
}

public struct IntroPlanSpec: Hashable, Sendable, Codable {
    public var subscriptionIds: [String]
    public var mode: OfferMode
    public var duration: OfferDuration
    public var numberOfPeriods: Int
    public var pricing: IntroPricing
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public var nominalDiscount: Decimal?
    public var filter: PlanFilter
    public var canary: Bool
    public init(subscriptionIds: [String], mode: OfferMode, duration: OfferDuration, numberOfPeriods: Int, pricing: IntroPricing,
                startDate: CalendarDate?, endDate: CalendarDate?, nominalDiscount: Decimal?, filter: PlanFilter, canary: Bool) {
        self.subscriptionIds = subscriptionIds; self.mode = mode; self.duration = duration; self.numberOfPeriods = numberOfPeriods
        self.pricing = pricing; self.startDate = startDate; self.endDate = endDate; self.nominalDiscount = nominalDiscount
        self.filter = filter; self.canary = canary
    }
}

public enum PromoAction: Hashable, Sendable, Codable {
    case create(subscriptionId: String, offerCode: String, name: String, mode: OfferMode, duration: OfferDuration,
                numberOfPeriods: Int, pricing: IntroPricing)
    case reprice(offerAscId: String, pricing: IntroPricing)
    case delete(offerAscId: String, confirmedUnusedByApp: Bool)
}

public struct PromoPlanSpec: Hashable, Sendable, Codable {
    public var action: PromoAction
    public init(action: PromoAction) { self.action = action }
}

public struct IAPPlanSpec: Hashable, Sendable, Codable {
    public var iapId: String
    public var baseTerritory: TerritoryCode
    public var prices: [TerritoryAmount]
    public var startDate: CalendarDate?
    public init(iapId: String, baseTerritory: TerritoryCode, prices: [TerritoryAmount], startDate: CalendarDate?) {
        self.iapId = iapId; self.baseTerritory = baseTerritory; self.prices = prices; self.startDate = startDate
    }
}

public struct RegularPlanSpec: Hashable, Sendable, Codable {
    public var subscriptionIds: [String]
    public var planType: PlanType
    public var prices: [TerritoryAmount]
    /// nil = no start date: the first price of a cell applies at once; a cell that already has a price gets
    /// today + minLeadDays (the Planner fills it in).
    public var startDate: CalendarDate?
    public var preserveCurrentPrice: Bool?
    public var skipIntroReplacement: [CellKey: String]
    public var filter: PlanFilter
    /// O5 (M4 Task 4.4): PAYG promo offers (asc id) re-priced in the same plan when the regular price drops.
    /// Decoded with decodeIfPresent (missing key = [:]), so specs stored before M4 still decode.
    public var promoRepricing: [String: IntroPricing]

    public init(subscriptionIds: [String], planType: PlanType, prices: [TerritoryAmount], startDate: CalendarDate?,
                preserveCurrentPrice: Bool?, skipIntroReplacement: [CellKey: String], filter: PlanFilter,
                promoRepricing: [String: IntroPricing] = [:]) {
        self.subscriptionIds = subscriptionIds; self.planType = planType; self.prices = prices; self.startDate = startDate
        self.preserveCurrentPrice = preserveCurrentPrice; self.skipIntroReplacement = skipIntroReplacement
        self.filter = filter; self.promoRepricing = promoRepricing
    }

    private enum CodingKeys: String, CodingKey {
        case subscriptionIds, planType, prices, startDate, preserveCurrentPrice, skipIntroReplacement, filter, promoRepricing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionIds = try c.decode([String].self, forKey: .subscriptionIds)
        planType = try c.decode(PlanType.self, forKey: .planType)
        prices = try c.decode([TerritoryAmount].self, forKey: .prices)
        startDate = try c.decodeIfPresent(CalendarDate.self, forKey: .startDate)
        preserveCurrentPrice = try c.decodeIfPresent(Bool.self, forKey: .preserveCurrentPrice)
        skipIntroReplacement = try c.decode([CellKey: String].self, forKey: .skipIntroReplacement)
        filter = try c.decode(PlanFilter.self, forKey: .filter)
        promoRepricing = try c.decodeIfPresent([String: IntroPricing].self, forKey: .promoRepricing) ?? [:]
    }
}

public struct WithdrawPlanSpec: Hashable, Sendable, Codable {
    public var planId: String
    public var itemSeqs: [Int]
    public init(planId: String, itemSeqs: [Int]) { self.planId = planId; self.itemSeqs = itemSeqs }
}

/// One row of desired texts. nil or empty field = keep the current text (L-D3).
public struct LocalizationEdit: Hashable, Sendable, Codable {
    public var owner: LocalizationOwner
    public var locale: String
    public var name: String?
    public var description: String?
    public var customAppName: String?
    public init(owner: LocalizationOwner, locale: String, name: String? = nil, description: String? = nil, customAppName: String? = nil) {
        self.owner = owner; self.locale = locale; self.name = name; self.description = description; self.customAppName = customAppName
    }
}

public struct LocalizationPlanSpec: Hashable, Sendable, Codable {
    public var edits: [LocalizationEdit]
    public init(edits: [LocalizationEdit]) { self.edits = edits }
}

public indirect enum PlanSpec: Hashable, Sendable, Codable {
    case importTable(ImportPlanSpec)
    case regular(RegularPlanSpec)
    case intro(IntroPlanSpec)
    case promo(PromoPlanSpec)
    case iap(IAPPlanSpec)
    case fix(findingIds: [Int64], underlying: PlanSpec)
    case withdraw(WithdrawPlanSpec)
    case localization(LocalizationPlanSpec)

    public var origin: PlanOrigin {
        switch self {
        case .importTable: return .importTable
        case .regular: return .regular
        case .intro: return .intro
        case .promo: return .promo
        case .iap: return .iap
        case .fix: return .fix
        case .withdraw: return .withdraw
        case .localization: return .localization
        }
    }

    /// The spec without `fix` wrappers.
    public var unwrapped: PlanSpec {
        if case let .fix(_, underlying) = self { return underlying.unwrapped }
        return self
    }
}

public struct CheckDiff: Hashable, Sendable, Codable {
    public var column: String
    public var cell: CellKey
    public var imported: Decimal
    public var snapped: Decimal?
    public var live: Decimal?
    public init(column: String, cell: CellKey, imported: Decimal, snapped: Decimal?, live: Decimal?) {
        self.column = column; self.cell = cell; self.imported = imported; self.snapped = snapped; self.live = live
    }
}

public struct Estimate: Hashable, Sendable, Codable {
    public var requests: Int
    public var minutes: Int
    public init(requests: Int, minutes: Int) { self.requests = requests; self.minutes = minutes }
}

public struct PlanDraft: Hashable, Sendable, Codable {
    public var spec: PlanSpec
    public var items: [PlannedItem]               // excluded cells already removed, dependants re-linked
    public var excluded: [CellKey]
    public var verdicts: [Verdict]
    public var checkDiffs: [CheckDiff]
    public var estimate: Estimate
    public var baseSyncId: Int64
    public var planHash: String                   // sha256 over JSONCoding of items
    public var verdictHash: String
    public var confirmationLevel: ConfirmationLevel
    public init(spec: PlanSpec, items: [PlannedItem], excluded: [CellKey], verdicts: [Verdict], checkDiffs: [CheckDiff],
                estimate: Estimate, baseSyncId: Int64, planHash: String, verdictHash: String, confirmationLevel: ConfirmationLevel) {
        self.spec = spec; self.items = items; self.excluded = excluded; self.verdicts = verdicts; self.checkDiffs = checkDiffs
        self.estimate = estimate; self.baseSyncId = baseSyncId; self.planHash = planHash; self.verdictHash = verdictHash
        self.confirmationLevel = confirmationLevel
    }
}

public struct PlanningContext: Sendable {
    public var snapshot: CatalogSnapshot
    public var config: WorkspaceConfig
    public var today: CalendarDate
    /// Latest X-Rate-Limit reading for the estimate and rule A7 (K9).
    public var rateLimit: RateLimitSnapshot?
    /// Stored items of the plans a WITHDRAW spec refers to, keyed by plan id (K9).
    public var referencedItems: [String: [StoredItem]]
    /// I7 (CR-11): LiveIntroCanaries.unlockedProducts(store:); copied into PlanSpecSummary.
    public var effectiveLiveIntroCanaryProducts: Set<String>

    public init(snapshot: CatalogSnapshot, config: WorkspaceConfig, today: CalendarDate,
                rateLimit: RateLimitSnapshot? = nil, referencedItems: [String: [StoredItem]] = [:],
                effectiveLiveIntroCanaryProducts: Set<String> = []) {
        self.snapshot = snapshot; self.config = config; self.today = today
        self.rateLimit = rateLimit; self.referencedItems = referencedItems
        self.effectiveLiveIntroCanaryProducts = effectiveLiveIntroCanaryProducts
    }
}
