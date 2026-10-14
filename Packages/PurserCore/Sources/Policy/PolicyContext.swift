import Foundation
import Domain
import Catalog
import ASCClient

public struct PolicyContext: Sendable {
    public var snapshot: CatalogSnapshot
    public var config: WorkspaceConfig
    public var today: CalendarDate
    public var spec: PlanSpecSummary
    public var items: [PlannedItem]
    public var liveBinding: PlanBinding?          // from preflight GET /v1/apps; nil while drafting
    public var liveBundleId: String?
    public var otherApplyingPlanIds: [String]
    /// Latest X-Rate-Limit reading (rule A7); nil when unknown. Additive to K8.
    public var rateLimit: RateLimitSnapshot?
    /// Items of the same plan already written when a resume re-checks the rest (`items`); empty while drafting.
    public var writtenItems: [PlannedItem]

    public init(snapshot: CatalogSnapshot, config: WorkspaceConfig, today: CalendarDate, spec: PlanSpecSummary,
                items: [PlannedItem], liveBinding: PlanBinding?, liveBundleId: String?, otherApplyingPlanIds: [String],
                rateLimit: RateLimitSnapshot? = nil, writtenItems: [PlannedItem] = []) {
        self.snapshot = snapshot; self.config = config; self.today = today; self.spec = spec; self.items = items
        self.liveBinding = liveBinding; self.liveBundleId = liveBundleId; self.otherApplyingPlanIds = otherApplyingPlanIds
        self.rateLimit = rateLimit; self.writtenItems = writtenItems
    }
}

/// What policy needs to know about the spec without depending on Planner.
public struct PlanSpecSummary: Hashable, Sendable, Codable {
    public var origin: PlanOrigin
    public var canary: Bool
    public var nominalDiscounts: [String: Decimal]   // product asc id -> nominal discount for intro targets
    public var skippedIntroReplacements: [CellKey: String]  // I8: cell -> reason
    /// I7 (CR-11): subscriptions whose live intro replacement was proven by an Effective CANARY plan.
    public var effectiveLiveIntroCanaryProducts: Set<String>

    public init(origin: PlanOrigin, canary: Bool, nominalDiscounts: [String: Decimal], skippedIntroReplacements: [CellKey: String],
                effectiveLiveIntroCanaryProducts: Set<String> = []) {
        self.origin = origin; self.canary = canary; self.nominalDiscounts = nominalDiscounts
        self.skippedIntroReplacements = skippedIntroReplacements
        self.effectiveLiveIntroCanaryProducts = effectiveLiveIntroCanaryProducts
    }

    private enum CodingKeys: String, CodingKey {
        case origin, canary, nominalDiscounts, skippedIntroReplacements, effectiveLiveIntroCanaryProducts
    }

    /// A missing effectiveLiveIntroCanaryProducts key decodes as [] (summaries encoded before CR-11).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decode(PlanOrigin.self, forKey: .origin)
        canary = try c.decode(Bool.self, forKey: .canary)
        nominalDiscounts = try c.decode([String: Decimal].self, forKey: .nominalDiscounts)
        skippedIntroReplacements = try c.decode([CellKey: String].self, forKey: .skippedIntroReplacements)
        effectiveLiveIntroCanaryProducts = try c.decodeIfPresent(Set<String>.self, forKey: .effectiveLiveIntroCanaryProducts) ?? []
    }
}
