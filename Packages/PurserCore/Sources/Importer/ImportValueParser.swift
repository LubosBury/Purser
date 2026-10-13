import Foundation
import Domain

/// Rule S3 value parsing, shared by the importer and pasted tables in the UI.
public enum ImportValueParser {
    /// Day counts accepted in free-trial columns.
    public static let trialDays: [Int: OfferDuration] = [
        3: .threeDays, 7: .oneWeek, 14: .twoWeeks, 30: .oneMonth,
        60: .twoMonths, 90: .threeMonths, 180: .sixMonths, 365: .oneYear,
    ]

    /// Plain digits with an optional "." fraction, > 0. Anything formatted ("1,99", "$1.99", "1 000") is rejected.
    public static func amount(_ text: String) -> Decimal? {
        guard text.wholeMatch(of: /[0-9]+(\.[0-9]+)?/) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }

    /// An OfferDuration raw value (any case) or a day count from `trialDays`.
    public static func trialDuration(_ text: String) -> OfferDuration? {
        if let duration = OfferDuration(rawValue: text.uppercased()) { return duration }
        guard text.wholeMatch(of: /[0-9]+(\.0+)?/) != nil, let days = Int(text.split(separator: ".")[0]) else { return nil }
        return trialDays[days]
    }
}
