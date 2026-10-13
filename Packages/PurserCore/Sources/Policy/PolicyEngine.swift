import CryptoKit
import Foundation
import Domain
import Catalog
import Store

public protocol PlanRule: Sendable {
    var id: RuleID { get }
    func evaluate(_ context: PolicyContext) -> [Verdict]
}

public protocol InvariantRule: Sendable {
    var id: RuleID { get }
    func check(_ snapshot: CatalogSnapshot, today: CalendarDate) -> [Verdict]
}

public struct PolicyEngine: Sendable {
    public static let defaultPlanRules: [any PlanRule] = DefaultRules.planRules
    public static let defaultInvariants: [any InvariantRule] = DefaultRules.invariants(nominalDiscounts: [:])   // A6, R3, I4, I5, O5

    public let planRules: [any PlanRule]
    public let invariantRules: [any InvariantRule]

    public init(planRules: [any PlanRule] = PolicyEngine.defaultPlanRules,
                invariants: [any InvariantRule] = PolicyEngine.defaultInvariants) {
        self.planRules = planRules
        self.invariantRules = invariants
    }

    /// Default invariants with I5 configured from the workspace import mapping (additive to K8).
    public static func invariants(for config: WorkspaceConfig) -> [any InvariantRule] {
        DefaultRules.invariants(nominalDiscounts: NominalDiscounts.from(mapping: config.importMapping))
    }

    public func evaluate(_ context: PolicyContext) -> [Verdict] {
        VerdictOrdering.sorted(planRules.flatMap { $0.evaluate(context) })
    }

    public func invariants(_ snapshot: CatalogSnapshot, today: CalendarDate) -> [Verdict] {
        VerdictOrdering.sorted(invariantRules.flatMap { $0.check(snapshot, today: today) })
    }

    /// C0 always; C1 on a production workspace or with any C1 verdict; C2 with any C2 verdict.
    public static func confirmationLevel(for verdicts: [Verdict], config: WorkspaceConfig) -> ConfirmationLevel {
        var level: ConfirmationLevel = config.isProduction ? .c1 : .c0
        for verdict in verdicts {
            if case let .confirm(required) = verdict.severity { level = max(level, required) }
        }
        return level
    }

    /// sha256 hex over JSONCoding of the sorted verdicts.
    public static func hash(_ verdicts: [Verdict]) -> String {
        let data = (try? JSONCoding.encoder.encode(VerdictOrdering.sorted(verdicts))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum VerdictOrdering {
    static func rank(_ severity: Severity) -> Int {
        switch severity {
        case .block(.plan): return 0
        case .block(.cell): return 1
        case .confirm(.c2): return 2
        case .confirm(.c1): return 3
        case .confirm(.c0): return 4
        case .pause: return 5
        case .warn: return 6
        }
    }

    static func sorted(_ verdicts: [Verdict]) -> [Verdict] {
        verdicts.sorted {
            ($0.rule.rawValue, rank($0.severity), $0.cell?.storageKey ?? "", $0.message, $0.riskClass ?? "")
                < ($1.rule.rawValue, rank($1.severity), $1.cell?.storageKey ?? "", $1.message, $1.riskClass ?? "")
        }
    }
}

/// Product asc id -> nominal discount of its intro targets (first column wins).
public enum NominalDiscounts {
    public static func from(mapping: ImportMapping?) -> [String: Decimal] {
        var result: [String: Decimal] = [:]
        for target in (mapping?.targets ?? []).sorted(by: { $0.column < $1.column }) {
            guard let nominal = target.nominalDiscount, result[target.productAscId] == nil else { continue }
            switch target.kind {
            case .introPayUpFront, .introPayAsYouGo: result[target.productAscId] = nominal
            default: continue
            }
        }
        return result
    }
}
