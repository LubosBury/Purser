import Foundation

/// The one JSON configuration for every *_json column and every hash input (sorted keys, ISO 8601 dates).
public enum JSONCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try decoder.decode(type, from: Data(string.utf8))
    }
}

/// ISO 8601 UTC timestamps with milliseconds, e.g. "2026-10-09T12:00:00.000Z", for every *_at / ts column.
public enum Timestamp {
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: TimeZone(identifier: "UTC")!)

    public static func string(_ date: Date) -> String {
        style.format(date)
    }

    public static func date(_ string: String) throws -> Date {
        try style.parse(string)
    }
}
