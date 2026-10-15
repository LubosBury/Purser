import Foundation
import Domain
import Store
import Policy
import Planner

/// What policy needs from a stored PlanSpec (K8 PlanSpecSummary). Mirrors the Planner's own summary.
enum PlanSpecSummarizer {
    static func summary(specJSON: String, config: WorkspaceConfig, unlockedCanaries: Set<String> = []) throws -> PlanSpecSummary {
        guard let spec = try? JSONCoding.decode(PlanSpec.self, from: specJSON) else {
            throw ExecutorError.corruptPlan("spec_json is not a PlanSpec")
        }
        return summary(spec, config: config, unlockedCanaries: unlockedCanaries)
    }

    /// I7 (M1 CR-11): products whose live-intro canary is Effective; the Planner copies the same set at draft time.
    static func summary(_ spec: PlanSpec, config: WorkspaceConfig, unlockedCanaries: Set<String>) -> PlanSpecSummary {
        var result = summary(spec, config: config)
        result.effectiveLiveIntroCanaryProducts = unlockedCanaries
        return result
    }

    static func summary(_ spec: PlanSpec, config: WorkspaceConfig) -> PlanSpecSummary {
        switch spec {
        case let .importTable(s):
            var discounts: [String: Decimal] = [:]
            for target in config.importMapping?.targets ?? [] where s.writeColumns.contains(target.column) {
                guard let discount = target.nominalDiscount else { continue }
                switch target.kind {
                case .introPayUpFront, .introPayAsYouGo, .introFreeTrial: discounts[target.productAscId] = discount
                default: break
                }
            }
            return PlanSpecSummary(origin: spec.origin, canary: s.canary, nominalDiscounts: discounts, skippedIntroReplacements: [:])
        case let .regular(s):
            return PlanSpecSummary(origin: spec.origin, canary: false, nominalDiscounts: [:], skippedIntroReplacements: s.skipIntroReplacement)
        case let .intro(s):
            var discounts: [String: Decimal] = [:]
            if let discount = s.nominalDiscount { for id in s.subscriptionIds { discounts[id] = discount } }
            return PlanSpecSummary(origin: spec.origin, canary: s.canary, nominalDiscounts: discounts, skippedIntroReplacements: [:])
        case .promo, .iap, .withdraw, .localization:
            return PlanSpecSummary(origin: spec.origin, canary: false, nominalDiscounts: [:], skippedIntroReplacements: [:])
        case let .fix(_, underlying):
            var inner = summary(underlying, config: config)
            inner.origin = .fix
            return inner
        }
    }
}
