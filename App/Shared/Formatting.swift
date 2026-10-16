import Foundation
import Domain

enum Formatting {
    static func price(_ amount: Decimal?, currency: CurrencyCode?) -> String {
        guard let amount else { return "—" }
        guard let currency else { return amount.description }
        return amount.formatted(.currency(code: currency.rawValue).locale(Locale(identifier: "en_US")))
    }

    static func percent(_ share: Decimal?) -> String {
        guard let share else { return "—" }
        return share.formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
    }

    static func period(_ period: SubscriptionPeriod) -> String {
        switch period {
        case .oneWeek: return "1 week"
        case .oneMonth: return "1 month"
        case .twoMonths: return "2 months"
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        case .oneYear: return "1 year"
        }
    }

    /// App Store Connect product state in words; an unknown state keeps Apple's name.
    static func productState(_ state: ProductState) -> String {
        switch state {
        case .approved: return "approved"
        case .readyToSubmit: return "ready to submit"
        case .missingMetadata: return "missing metadata"
        case .developerActionNeeded: return "developer action needed"
        case .waitingForReview: return "waiting for review"
        case .inReview: return "in review"
        default: return state.rawValue
        }
    }

    static func iapType(_ type: String) -> String {
        switch type {
        case "NON_CONSUMABLE": return "non-consumable"
        case "CONSUMABLE": return "consumable"
        case "NON_RENEWING_SUBSCRIPTION": return "non-renewing subscription"
        default: return type
        }
    }

    static func date(_ date: CalendarDate?) -> String {
        date?.iso ?? "—"
    }

    /// Local date and time in en_US form, e.g. "10/16/2026, 12:20 PM".
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .shortened, locale: Locale(identifier: "en_US")))
    }

    static func age(since date: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "a moment ago" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }
}
