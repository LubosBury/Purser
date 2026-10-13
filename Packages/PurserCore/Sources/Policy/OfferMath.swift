import Foundation
import Domain

/// Shared arithmetic for intro and promo prices (rules I2, I4, I5, O5 and the planner).
public enum OfferMath {
    static func days(_ duration: OfferDuration) -> Int {
        switch duration {
        case .threeDays: return 3
        case .oneWeek: return 7
        case .twoWeeks: return 14
        case .oneMonth: return 30
        case .twoMonths: return 60
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .oneYear: return 365
        }
    }

    static func days(_ period: SubscriptionPeriod) -> Int {
        switch period {
        case .oneWeek: return 7
        case .oneMonth: return 30
        case .twoMonths: return 60
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .oneYear: return 365
        }
    }

    /// How many regular periods one offer price stands for: PAY_UP_FRONT covers floor(duration / period) periods
    /// (at least 1), PAY_AS_YOU_GO is priced per period (1). Free trials have no price (1).
    public static func regularMultiplier(mode: OfferMode, duration: OfferDuration, period: SubscriptionPeriod) -> Decimal {
        guard mode == .payUpFront else { return 1 }
        return Decimal(max(1, days(duration) / days(period)))
    }

    /// The OfferDuration with the same length as the subscription period (PAY_AS_YOU_GO duration).
    public static func duration(matching period: SubscriptionPeriod) -> OfferDuration {
        switch period {
        case .oneWeek: return .oneWeek
        case .oneMonth: return .oneMonth
        case .twoMonths: return .twoMonths
        case .threeMonths: return .threeMonths
        case .sixMonths: return .sixMonths
        case .oneYear: return .oneYear
        }
    }

    /// Rule I2 [T1-12, T1-13]: allowed shapes per subscription period.
    public static func isValidShape(mode: OfferMode, duration: OfferDuration, periods: Int, period: SubscriptionPeriod) -> Bool {
        switch mode {
        case .freeTrial:
            return periods == 1
        case .payUpFront:
            return periods == 1 && [.oneMonth, .twoMonths, .threeMonths, .sixMonths, .oneYear].contains(duration)
        case .payAsYouGo:
            guard duration == Self.duration(matching: period), periods >= 1 else { return false }
            return periods * days(period) <= 365 + 7 && (period != .oneYear || periods == 1)
        }
    }
}
