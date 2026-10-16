import Foundation
import SwiftUI
import Domain
import Store

enum PlanFormatting {
    /// 0.2 -> "20.0%"; nil -> "".
    static func percent(_ fraction: Decimal?) -> String {
        guard var value = fraction.map({ $0 * 100 }) else { return "" }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 1, .plain)
        return "\(rounded)%"
    }

    static func amount(_ value: Decimal?) -> String { value.map { "\($0)" } ?? "" }

    static func severityLabel(_ severity: Severity) -> String {
        switch severity {
        case .block(.plan): return "BLOCK · PLAN"
        case .block(.cell): return "BLOCK · CELL"
        case let .confirm(level): return "C\(level.rawValue)"
        case .warn: return "WARN"
        case .pause: return "PAUSE"
        }
    }

    static func ruleTitle(_ rule: RuleID?) -> String {
        switch rule?.rawValue {
        case "I4": return "intro ≥ regular price"
        case "I5": return "discount smaller than nominal"
        case "R3": return "monthly / yearly ratio"
        case "A6": return "outside availability"
        case "O5": return "promo ≥ regular price"
        default: return ""
        }
    }

    /// 0.125 -> "+12.5%"; the sign is always written so colour is not the only signal.
    static func signedPercent(_ fraction: Decimal?) -> String {
        guard let fraction else { return "" }
        let text = percent(fraction)
        if fraction > 0 { return "+" + text }
        return text.replacingOccurrences(of: "-", with: "−")
    }

    static func originLabel(_ origin: PlanOrigin) -> String {
        switch origin {
        case .importTable: return "Table import"
        case .regular: return "Regular price"
        case .intro: return "Introductory offer"
        case .promo: return "Promotional offer"
        case .iap: return "One-time purchase"
        case .fix: return "Repair"
        case .withdraw: return "Rollback"
        case .localization: return "Localization"
        }
    }

    /// "Regular price · yearly price adjustment"; the reason stands in for a plan name.
    static func title(_ plan: StoredPlan) -> String {
        guard let reason = plan.reason, !reason.isEmpty else { return originLabel(plan.origin) }
        return "\(originLabel(plan.origin)) · \(reason)"
    }

    static func stateBadge(_ plan: StoredPlan) -> PurserBadge {
        switch plan.state {
        case .draft: return PurserBadge(text: "Draft")
        case .applying:
            if let pause = plan.pauseReason { return PurserBadge(text: "Paused: \(pause.rawValue.uppercased())", kind: .warning) }
            return PurserBadge(text: "Writing", kind: .info)
        case .stale: return PurserBadge(text: "Stale", kind: .warning)
        case .scheduled: return PurserBadge(text: "Scheduled", kind: .info)
        case .effective: return PurserBadge(text: "In effect", kind: .success)
        case .partiallyApplied: return PurserBadge(text: "Partially written", kind: .warning)
        case .closed: return PurserBadge(text: "Closed")
        case .cancelled: return PurserBadge(text: "Cancelled")
        }
    }

    static func badgeKind(_ severity: Severity) -> PurserBadge.Kind {
        switch severity {
        case .block: return .danger
        case .warn, .pause, .confirm(.c2): return .warning
        case .confirm: return .info
        }
    }

    static func severityWord(_ severity: Severity) -> String {
        switch severity {
        case .block: return "BLOCK"
        case let .confirm(level): return "C\(level.rawValue)"
        case .warn: return "WARN"
        case .pause: return "PAUSE"
        }
    }

    static func age(since date: Date?) -> String {
        guard let date else { return "?" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 48 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / 1440) d"
    }
}
