import Foundation

/// A calendar day in UTC, serialized as "YYYY-MM-DD".
public struct CalendarDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses "YYYY-MM-DD"; returns nil for any other shape or an impossible date.
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = CalendarDate.utc.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let back = CalendarDate.utc.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func today(now: Date) -> CalendarDate {
        let c = utc.dateComponents([.year, .month, .day], from: now)
        return CalendarDate(year: c.year!, month: c.month!, day: c.day!)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }
    public var startOfDayUTC: Date { CalendarDate.utc.date(from: DateComponents(year: year, month: month, day: day))! }

    public func adding(days: Int) -> CalendarDate {
        CalendarDate.today(now: CalendarDate.utc.date(byAdding: .day, value: days, to: startOfDayUTC)!)
    }

    public static func < (l: Self, r: Self) -> Bool { (l.year, l.month, l.day) < (r.year, r.month, r.day) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = CalendarDate(iso: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}
