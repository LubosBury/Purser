import Foundation

public enum PlanOrigin: String, Codable, Sendable {
    case importTable = "IMPORT", regular = "REGULAR", intro = "INTRO", promo = "PROMO", iap = "IAP", fix = "FIX", withdraw = "WITHDRAW"
}

public enum PlanState: String, Codable, Sendable, CaseIterable {
    case draft, applying, stale, scheduled, effective, partiallyApplied, closed, cancelled
}

public enum PauseReason: String, Codable, Sendable, CaseIterable {
    case user, quit, sleep, crash, network, rate, agreement, auth, systemic
    /// RATE and NETWORK resume on their own within the same apply session (spec §6).
    public var resumesAutomatically: Bool { self == .rate || self == .network }
}

public enum PlanEndReason: String, Codable, Sendable {
    case superseded, withdrawn, replanned, abandoned, cancelledByUser, abortedNoWrites
}

public enum ConfirmationLevel: Int, Codable, Sendable, Comparable {
    case c0 = 0, c1 = 1, c2 = 2
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

public enum ItemOp: String, Codable, Sendable {
    case post = "POST", delete = "DELETE", patchEnd = "PATCH_END", patchPrices = "PATCH_PRICES", scheduleReplace = "SCHEDULE_REPLACE"
}

public enum ItemState: String, Codable, Sendable, CaseIterable {
    case pending, inFlight, done, failed, mismatch, stale, skipped, superseded, withdrawn, effective
}

public enum ItemFlag: String, Codable, Sendable {
    case noOffer = "NO_OFFER", lostScheduledChange = "LOST_SCHEDULED_CHANGE", limitedByI5 = "LIMITED_I5"
}

public struct NewRegularPrice: Hashable, Sendable, Codable {
    public var subscriptionId: String
    public var territory: TerritoryCode
    public var planType: PlanType
    public var pricePointId: String
    public var startDate: CalendarDate?
    public var preserveCurrentPrice: Bool
    public init(subscriptionId: String, territory: TerritoryCode, planType: PlanType, pricePointId: String, startDate: CalendarDate?, preserveCurrentPrice: Bool) {
        self.subscriptionId = subscriptionId; self.territory = territory; self.planType = planType
        self.pricePointId = pricePointId; self.startDate = startDate; self.preserveCurrentPrice = preserveCurrentPrice
    }
}

public struct NewIntroOffer: Hashable, Sendable, Codable {
    public var subscriptionId: String
    public var territory: TerritoryCode
    public var planType: PlanType
    public var mode: OfferMode
    public var duration: OfferDuration
    public var numberOfPeriods: Int
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public var pricePointId: String?       // nil for FREE_TRIAL (rule I3)
    public init(subscriptionId: String, territory: TerritoryCode, planType: PlanType, mode: OfferMode, duration: OfferDuration,
                numberOfPeriods: Int, startDate: CalendarDate?, endDate: CalendarDate?, pricePointId: String?) {
        self.subscriptionId = subscriptionId; self.territory = territory; self.planType = planType; self.mode = mode
        self.duration = duration; self.numberOfPeriods = numberOfPeriods; self.startDate = startDate
        self.endDate = endDate; self.pricePointId = pricePointId
    }
}

public struct NewPromoPrice: Hashable, Sendable, Codable {
    public var territory: TerritoryCode
    public var pricePointId: String?       // nil for FREE_TRIAL rows (rule O4)
    public init(territory: TerritoryCode, pricePointId: String?) { self.territory = territory; self.pricePointId = pricePointId }
}

public struct NewPromoOffer: Hashable, Sendable, Codable {
    public var subscriptionId: String
    public var offerCode: String
    public var name: String
    public var mode: OfferMode
    public var duration: OfferDuration
    public var numberOfPeriods: Int
    public var planType: PlanType
    public var prices: [NewPromoPrice]
    public init(subscriptionId: String, offerCode: String, name: String, mode: OfferMode, duration: OfferDuration,
                numberOfPeriods: Int, planType: PlanType, prices: [NewPromoPrice]) {
        self.subscriptionId = subscriptionId; self.offerCode = offerCode; self.name = name; self.mode = mode
        self.duration = duration; self.numberOfPeriods = numberOfPeriods; self.planType = planType
        self.prices = prices.sorted { $0.territory < $1.territory }
    }
}

public struct NewIAPManualPrice: Hashable, Sendable, Codable {
    public var territory: TerritoryCode
    public var pricePointId: String
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public init(territory: TerritoryCode, pricePointId: String, startDate: CalendarDate?, endDate: CalendarDate?) {
        self.territory = territory; self.pricePointId = pricePointId; self.startDate = startDate; self.endDate = endDate
    }
}

public struct NewIAPSchedule: Hashable, Sendable, Codable {
    public var iapId: String
    public var baseTerritory: TerritoryCode
    public var manualPrices: [NewIAPManualPrice]
    public init(iapId: String, baseTerritory: TerritoryCode, manualPrices: [NewIAPManualPrice]) {
        self.iapId = iapId; self.baseTerritory = baseTerritory
        self.manualPrices = manualPrices.sorted {
            ($0.territory.rawValue, $0.startDate?.iso ?? "") < ($1.territory.rawValue, $1.startDate?.iso ?? "")
        }
    }
}

/// Exactly one ASC request.
public enum WritePayload: Hashable, Sendable, Codable {
    case createRegularPrice(NewRegularPrice)
    case deleteRegularPrice(ascId: String)
    case createIntro(NewIntroOffer)
    case endIntro(ascId: String, endDate: CalendarDate)
    case deleteIntro(ascId: String)
    case createPromo(NewPromoOffer)
    case replacePromoPrices(ascId: String, prices: [NewPromoPrice])
    case deletePromo(ascId: String)
    case replaceIAPSchedule(NewIAPSchedule)

    public var op: ItemOp {
        switch self {
        case .createRegularPrice, .createIntro, .createPromo: return .post
        case .deleteRegularPrice, .deleteIntro, .deletePromo: return .delete
        case .endIntro: return .patchEnd
        case .replacePromoPrices: return .patchPrices
        case .replaceIAPSchedule: return .scheduleReplace
        }
    }
}

public struct PlannedItem: Hashable, Sendable, Codable {
    public var seq: Int
    public var cell: CellKey
    public var payload: WritePayload
    public var before: CellState            // expected live state of the cell after all dependsOn predecessors in the same cell
    public var target: CellState
    public var naturalKey: String           // NaturalKey.of(payload)
    public var dependsOn: [Int]
    public var rules: [RuleID]
    public var flags: [ItemFlag]
    public var op: ItemOp { payload.op }

    public init(seq: Int, cell: CellKey, payload: WritePayload, before: CellState, target: CellState,
                dependsOn: [Int] = [], rules: [RuleID] = [], flags: [ItemFlag] = []) {
        self.seq = seq; self.cell = cell; self.payload = payload; self.before = before; self.target = target
        self.naturalKey = NaturalKey.of(payload); self.dependsOn = dependsOn; self.rules = rules; self.flags = flags
    }
}

public enum BlockScope: String, Codable, Sendable { case plan, cell }

public enum Severity: Hashable, Sendable, Codable {
    case block(BlockScope)
    case confirm(ConfirmationLevel)
    case warn
    case pause
}

public struct Verdict: Hashable, Sendable, Codable {
    public var rule: RuleID
    public var severity: Severity
    public var cell: CellKey?
    public var message: String
    /// For C2 verdicts: the risk class the user must tick, e.g. "R7 regular price decrease".
    public var riskClass: String?
    public init(rule: RuleID, severity: Severity, cell: CellKey?, message: String, riskClass: String? = nil) {
        self.rule = rule; self.severity = severity; self.cell = cell; self.message = message; self.riskClass = riskClass
    }
}
