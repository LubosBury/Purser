import Foundation
import Domain
import Catalog
import Planner
import MCPBridge

/// Reads the arguments of the localization tools. A subscription or an in-app purchase is named by Product ID or ASC id,
/// a subscription group by "group:<reference name>" (or "group:<ASC id>"); `LocalizationTemplate.owner(for:snapshot:)` is
/// the one resolver, the same one that reads the localization table and create_localization_plan.
public struct LocalizationArguments: Sendable {
    public let arguments: JSONValue
    public let snapshot: CatalogSnapshot

    public init(_ arguments: JSONValue, snapshot: CatalogSnapshot) {
        self.arguments = arguments; self.snapshot = snapshot
    }

    /// The owners named in `products`, in the given order without repeats; every owner of the catalog when the list is
    /// absent or empty.
    public func owners() throws -> [LocalizationOwner] {
        guard let values = arguments["products"]?.arrayValue, !values.isEmpty else { return snapshot.owners() }
        var owners: [LocalizationOwner] = []
        for value in values {
            guard let reference = value.stringValue?.trimmingCharacters(in: .whitespaces), !reference.isEmpty else {
                throw ToolArgumentError("“products” must contain only non-empty strings.")
            }
            let owner = try owner(reference)
            if !owners.contains(owner) { owners.append(owner) }
        }
        return owners
    }

    /// Where an owner reference that could not be resolved can be looked up: get_localizations shows groups too (list_products
    /// does not) and names every owner the way the localization tools take it back.
    static let ownerHint = "get_localizations shows every product and group with the name to use."

    public func owner(_ reference: String) throws -> LocalizationOwner {
        let found = LocalizationTemplate.owner(for: reference, snapshot: snapshot)
        guard let owner = found.owner else {
            let problem = found.problem ?? "unknown product"
            throw ToolArgumentError(problem.prefix(1).uppercased() + problem.dropFirst() + ". " + Self.ownerHint)
        }
        return owner
    }

    /// nil when the list is absent or empty (= every locale).
    public func locales() throws -> Set<String>? {
        guard let values = arguments["locales"]?.arrayValue, !values.isEmpty else { return nil }
        return Set(try values.map { value -> String in
            guard let locale = value.stringValue?.trimmingCharacters(in: .whitespaces), !locale.isEmpty else {
                throw ToolArgumentError("“locales” must contain only non-empty strings, e.g. [\"en-US\", \"cs\"].")
            }
            return locale
        })
    }
}
