import CryptoKit
import Foundation
import Domain
import Store
import Catalog
import Policy

public struct Planner: Sendable {
    private let policy: PolicyEngine

    public init(policy: PolicyEngine) { self.policy = policy }

    /// Builds items, snaps to price points (S4), runs policy, removes BLOCK·CELL cells and their dependants,
    /// computes estimate, hashes and confirmation level. Throws only on programmer errors.
    public func plan(_ spec: PlanSpec, context: PlanningContext) throws -> PlanDraft {
        var builder = PlanBuilder(context: context, origin: spec.origin)
        do {
            try builder.build(spec)
        } catch let error as PlanningError {
            builder = PlanBuilder(context: context, origin: spec.origin)
            builder.verdicts = [error.verdict]
        }
        let builderVerdicts = builder.verdicts
        var excluded = Set(builderVerdicts.compactMap { Self.isBlockCell($0) ? $0.cell : nil })
        let first = Exclusion.apply(excluded, to: builder.sink.items)
        var items = first.items
        excluded.formUnion(first.excluded)

        var policyVerdicts: [Verdict] = []
        var exclusionVerdicts: [Verdict] = []
        for _ in 0..<5 {
            policyVerdicts = policy.evaluate(PolicyContext(snapshot: context.snapshot, config: context.config, today: context.today,
                                                           spec: builder.summary, items: items, liveBinding: nil, liveBundleId: nil,
                                                           otherApplyingPlanIds: [], rateLimit: context.rateLimit))
            let itemCells = Set(items.map(\.cell))
            let blocked = Set(policyVerdicts.compactMap { Self.isBlockCell($0) ? $0.cell : nil }).intersection(itemCells)
            if blocked.isEmpty { break }
            exclusionVerdicts += policyVerdicts.filter { Self.isBlockCell($0) && $0.cell.map(blocked.contains) == true }
            let result = Exclusion.apply(blocked, to: items)
            items = result.items
            excluded.formUnion(result.excluded)
        }

        let verdicts = Self.sorted(Array(Set(builderVerdicts + exclusionVerdicts + policyVerdicts)))
        let requests = RequestEstimator.requests(items: items)
        let itemsData = try JSONCoding.encoder.encode(items)
        return PlanDraft(
            spec: spec,
            items: items,
            excluded: excluded.sorted { $0.storageKey < $1.storageKey },
            verdicts: verdicts,
            checkDiffs: builder.checkDiffs.sorted { ($0.column, $0.cell.storageKey) < ($1.column, $1.cell.storageKey) },
            estimate: Estimate(requests: requests, minutes: RequestEstimator.minutes(requests: requests, rateLimit: context.rateLimit)),
            baseSyncId: context.snapshot.syncId,
            planHash: SHA256.hash(data: itemsData).map { String(format: "%02x", $0) }.joined(),
            verdictHash: PolicyEngine.hash(verdicts),
            confirmationLevel: PolicyEngine.confirmationLevel(for: verdicts, config: context.config))
    }

    static func isBlockCell(_ verdict: Verdict) -> Bool {
        if case .block(.cell) = verdict.severity { return true }
        return false
    }

    static func sorted(_ verdicts: [Verdict]) -> [Verdict] {
        func rank(_ s: Severity) -> Int {
            switch s {
            case .block(.plan): return 0
            case .block(.cell): return 1
            case .confirm(.c2): return 2
            case .confirm(.c1): return 3
            case .confirm(.c0): return 4
            case .pause: return 5
            case .warn: return 6
            }
        }
        return verdicts.sorted {
            (rank($0.severity), $0.rule.rawValue, $0.cell?.storageKey ?? "", $0.message)
                < (rank($1.severity), $1.rule.rawValue, $1.cell?.storageKey ?? "", $1.message)
        }
    }
}
