import Foundation

/// ASC territory id (ISO 3166-1 alpha-3 as used by ASC, e.g. "USA", "CZE"; Kosovo is "XKS").
public struct TerritoryCode: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue.uppercased() }
    public init(stringLiteral value: String) { self.init(value) }
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    public var description: String { rawValue }
}

/// ISO 4217 currency code as returned by ASC territories.
public struct CurrencyCode: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue.uppercased() }
    public init(stringLiteral value: String) { self.init(value) }
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
}

/// Rule identifier from the spec, e.g. "I4", "R7".
public struct RuleID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    public var description: String { rawValue }
}
