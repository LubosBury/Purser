import Foundation

/// Any JSON value inside JSON:API attributes. Numbers decode as Decimal (amounts are never Double).
/// Decoding order: null, Bool, Decimal, String, array, object.
public enum JSONValue: Hashable, Sendable, Decodable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    /// The string of `.string`, else nil.
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The value of `.bool`, else nil.
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The value of `.number` when it is an exact integer that fits Int, else nil.
    public var intValue: Int? {
        guard case let .number(value) = self else { return nil }
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard rounded == value else { return nil }
        // An integral Decimal prints without a fraction; Int(_:) returns nil when it does not fit.
        return Int(rounded.description)
    }
}

public struct JSONAPIResourceIdentifier: Hashable, Sendable, Decodable {
    public let type: String
    public let id: String
}

public struct JSONAPIRelationship: Sendable, Decodable {
    /// nil when the response carries no linkage (relationship not included); [] for an empty or null linkage.
    public let data: [JSONAPIResourceIdentifier]?

    private enum CodingKeys: String, CodingKey { case data }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if !container.contains(.data) {
            data = nil
        } else if try container.decodeNil(forKey: .data) {
            data = []
        } else if let one = try? container.decode(JSONAPIResourceIdentifier.self, forKey: .data) {
            data = [one]
        } else {
            data = try container.decode([JSONAPIResourceIdentifier].self, forKey: .data)
        }
    }
}

public struct JSONAPIResource: Sendable, Decodable {
    public let type: String
    public let id: String
    public let attributes: [String: JSONValue]
    public let relationships: [String: JSONAPIRelationship]

    private enum CodingKeys: String, CodingKey { case type, id, attributes, relationships }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        attributes = try container.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
        relationships = try container.decodeIfPresent([String: JSONAPIRelationship].self, forKey: .relationships) ?? [:]
    }

    /// attributes[key]?.stringValue
    public func string(_ key: String) -> String? {
        attributes[key]?.stringValue
    }

    /// attributes[key]?.intValue
    public func int(_ key: String) -> Int? {
        attributes[key]?.intValue
    }

    /// attributes[key]?.boolValue
    public func bool(_ key: String) -> Bool? {
        attributes[key]?.boolValue
    }

    /// The first linked id of a relationship (relationships[name]?.data?.first?.id).
    public func relatedID(_ relationship: String) -> String? {
        relationships[relationship]?.data?.first?.id
    }
}

/// Generic JSON:API document; DTO mapping lives in LiveASCClient+*.swift files.
public struct JSONAPIDocument: Decodable, Sendable {
    /// One or many primary resources, always as an array.
    public let data: [JSONAPIResource]
    public let isCollection: Bool
    public let included: [JSONAPIResource]
    public let nextURL: URL?
    public let total: Int?

    private enum CodingKeys: String, CodingKey { case data, included, links, meta }
    private struct Links: Decodable { let next: String? }
    private struct Meta: Decodable {
        struct Paging: Decodable { let total: Int? }
        let paging: Paging?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if (try? container.decodeNil(forKey: .data)) ?? true {
            data = []
            isCollection = false
        } else if let many = try? container.decode([JSONAPIResource].self, forKey: .data) {
            data = many
            isCollection = true
        } else {
            data = [try container.decode(JSONAPIResource.self, forKey: .data)]
            isCollection = false
        }
        included = try container.decodeIfPresent([JSONAPIResource].self, forKey: .included) ?? []
        nextURL = try container.decodeIfPresent(Links.self, forKey: .links)?.next.flatMap(URL.init(string:))
        total = try container.decodeIfPresent(Meta.self, forKey: .meta)?.paging?.total
    }

    public func includedResource(type: String, id: String) -> JSONAPIResource? {
        included.first { $0.type == type && $0.id == id }
    }
}
