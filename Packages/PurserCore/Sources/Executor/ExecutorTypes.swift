import Foundation
import Domain

public struct ConfirmationRequest: Hashable, Sendable {
    public var planId: String
    public var level: ConfirmationLevel
    public var verdicts: [Verdict]
    public var excluded: [CellKey]
    public var riskClasses: [String: Int]      // C2 class -> number of cells
    public var verdictHashChanged: Bool
    public var appName: String

    public init(planId: String, level: ConfirmationLevel, verdicts: [Verdict], excluded: [CellKey], riskClasses: [String: Int],
                verdictHashChanged: Bool, appName: String) {
        self.planId = planId; self.level = level; self.verdicts = verdicts; self.excluded = excluded
        self.riskClasses = riskClasses; self.verdictHashChanged = verdictHashChanged; self.appName = appName
    }
}

public struct ConfirmationResponse: Hashable, Sendable {
    public var accepted: Bool
    public var acknowledgedExclusions: Bool
    public var typedAppName: String?
    public var reason: String?
    public var checkedRiskClasses: Set<String>

    public init(accepted: Bool, acknowledgedExclusions: Bool, typedAppName: String?, reason: String?, checkedRiskClasses: Set<String>) {
        self.accepted = accepted; self.acknowledgedExclusions = acknowledgedExclusions; self.typedAppName = typedAppName
        self.reason = reason; self.checkedRiskClasses = checkedRiskClasses
    }
}

public enum ExecutorEvent: Sendable {
    case planState(planId: String, state: PlanState, pause: PauseReason?)
    case item(planId: String, seq: Int, state: ItemState)
    case progress(planId: String, done: Int, total: Int, budgetRemaining: Int?, etaMinutes: Int?)
}

/// Points where a test or a DEBUG drill (spike S8) may stop the executor as if the process died.
public enum ExecutorStep: Hashable, Sendable, CustomStringConvertible {
    case beforeSend(seq: Int)
    case afterHTTPSent(seq: Int)
    case afterResponse(seq: Int)
    case afterItemCommitted(seq: Int)
    case beforeVerify(product: String)
    case afterVerify(product: String)

    public var description: String {
        switch self {
        case let .beforeSend(seq): return "beforeSend:\(seq)"
        case let .afterHTTPSent(seq): return "afterHTTPSent:\(seq)"
        case let .afterResponse(seq): return "afterResponse:\(seq)"
        case let .afterItemCommitted(seq): return "afterItemCommitted:\(seq)"
        case let .beforeVerify(product): return "beforeVerify:\(product)"
        case let .afterVerify(product): return "afterVerify:\(product)"
        }
    }

    /// Parses `description`, e.g. "afterItemCommitted:7" (used by the S8 drill environment variable).
    public init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "beforeSend": guard let seq = Int(parts[1]) else { return nil }; self = .beforeSend(seq: seq)
        case "afterHTTPSent": guard let seq = Int(parts[1]) else { return nil }; self = .afterHTTPSent(seq: seq)
        case "afterResponse": guard let seq = Int(parts[1]) else { return nil }; self = .afterResponse(seq: seq)
        case "afterItemCommitted": guard let seq = Int(parts[1]) else { return nil }; self = .afterItemCommitted(seq: seq)
        case "beforeVerify": self = .beforeVerify(product: parts[1])
        case "afterVerify": self = .afterVerify(product: parts[1])
        default: return nil
        }
    }
}
