import Foundation
import Domain
import Catalog
import Importer
import Planner
import MCPBridge

/// Reads the arguments of create_localization_plan: rows of {product, locale, name?, description?,
/// custom_app_name?} in the shape of the localization table, resolved the same way an imported table is.
public struct LocalizationPlanArguments: Sendable {
    public let arguments: JSONValue
    public let snapshot: CatalogSnapshot

    public init(_ arguments: JSONValue, snapshot: CatalogSnapshot) {
        self.arguments = arguments; self.snapshot = snapshot
    }

    public var reason: String? {
        let text = arguments["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// The fields of a row, in the order the messages name them.
    static let rowFields = ["product", "locale", "name", "description", "custom_app_name"]

    /// The rows as table rows numbered from 1; an empty text is nil (keep the current text). A field the tool does not know
    /// (a misspelt "customAppName") refuses the call instead of leaving the text unchanged.
    public func rows() throws -> [LocalizationTableRow] {
        guard let items = arguments["rows"]?.arrayValue, !items.isEmpty else {
            throw ToolArgumentError("“rows” is required: a list of {product, locale, name, description, custom_app_name}.")
        }
        return try items.enumerated().map { index, item in
            if case let .object(members) = item, let unknown = members.keys.filter({ !Self.rowFields.contains($0) }).sorted().first {
                throw ToolArgumentError("Row \(index + 1): unknown field “\(unknown)”; use \(Self.rowFields.joined(separator: ", ")).")
            }
            func text(_ key: String) throws -> String? {
                guard let value = item[key], !value.isNull else { return nil }
                guard let string = value.stringValue else { throw ToolArgumentError("Row \(index + 1): “\(key)” must be a string.") }
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard let product = try text("product") else { throw ToolArgumentError("Row \(index + 1) needs “product”.") }
            guard let locale = try text("locale") else { throw ToolArgumentError("Row \(index + 1) needs “locale”.") }
            return LocalizationTableRow(rowNumber: index + 1, product: product, locale: locale, name: try text("name"),
                                        description: try text("description"), customAppName: try text("custom_app_name"))
        }
    }

    /// The Draft's spec. A row Purser cannot place refuses the whole call, so nothing is planned from half a table. Owners
    /// are resolved by `LocalizationTemplate`, as in get_localizations, which the refusal points to when a row names no
    /// owner or more than one.
    public func spec() throws -> PlanSpec {
        let rows = try rows()
        let resolved = LocalizationTemplate.resolve(rows, snapshot: snapshot)
        guard resolved.problems.isEmpty else {
            let unresolved = rows.contains { LocalizationTemplate.owner(for: $0.product, snapshot: snapshot).owner == nil }
            throw ToolArgumentError("Nothing was planned. " + resolved.problems.joined(separator: " ")
                                    + (unresolved ? " " + LocalizationArguments.ownerHint : ""))
        }
        return .localization(LocalizationPlanSpec(edits: resolved.edits))
    }
}
