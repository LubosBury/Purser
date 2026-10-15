import Foundation
import Domain

/// Paths of the v2 localization writes. `WritePaths.request(for:)` refuses `.setLocalization`: the Executor resolves the
/// request first and builds it from these functions.
extension WritePaths {
    package static func localizationCollection(_ kind: LocalizationOwnerKind) -> String {
        switch kind {
        case .subscription: return "subscriptionLocalizations"
        case .iap: return "inAppPurchaseLocalizations"
        case .group: return "subscriptionGroupLocalizations"
        }
    }

    package static func createLocalization(_ kind: LocalizationOwnerKind) -> (method: String, path: String) {
        ("POST", "/v2/\(localizationCollection(kind))")
    }

    package static func updateLocalization(_ kind: LocalizationOwnerKind, id: String) -> (method: String, path: String) {
        ("PATCH", "/v2/\(localizationCollection(kind))/\(id)")
    }
}

/// Bodies of the localization writes. A nil field is never sent; a group sends customAppName, never a description.
extension WriteBodies {
    package static func versionType(_ kind: LocalizationOwnerKind) -> String {
        switch kind {
        case .subscription: return "subscriptionVersions"
        case .iap: return "inAppPurchaseVersions"
        case .group: return "subscriptionGroupVersions"
        }
    }

    static func localizationAttributes(_ kind: LocalizationOwnerKind, _ text: LocalizationText) -> [String: JSONBody] {
        var attributes: [String: JSONBody] = ["name": .string(text.name)]
        switch kind {
        case .group:
            if let value = text.customAppName { attributes["customAppName"] = .string(value) }
        case .subscription, .iap:
            if let value = text.description { attributes["description"] = .string(value) }
        }
        return attributes
    }

    package static func createLocalization(versionId: String, owner: LocalizationOwner, locale: String, text: LocalizationText) -> JSONBody {
        var attributes = localizationAttributes(owner.kind, text)
        attributes["locale"] = .string(locale)
        return .object(["data": .object([
            "type": .string(WritePaths.localizationCollection(owner.kind)),
            "attributes": .object(attributes),
            "relationships": .object(["version": ref(versionType(owner.kind), versionId)]),
        ])])
    }

    /// Only name and the second text; the locale never changes.
    package static func updateLocalization(localizationId: String, owner: LocalizationOwner, text: LocalizationText) -> JSONBody {
        .object(["data": .object([
            "type": .string(WritePaths.localizationCollection(owner.kind)),
            "id": .string(localizationId),
            "attributes": .object(localizationAttributes(owner.kind, text)),
        ])])
    }
}

extension WriteResponses {
    /// The row a localization POST created; attributes the response leaves out fall back to the request.
    package static func localizationRow(_ document: JSONAPIDocument?, owner: LocalizationOwner, versionId: String, locale: String,
                                        text: LocalizationText) throws -> LocalizationRow {
        let resource = try primary(document, type: WritePaths.localizationCollection(owner.kind))
        let returned = LocalizationText(
            name: resource.string("name") ?? text.name,
            description: owner.kind == .group ? nil : (resource.string("description") ?? text.description),
            customAppName: owner.kind == .group ? (resource.string("customAppName") ?? text.customAppName) : nil)
        return LocalizationRow(ascId: resource.id, owner: owner, versionId: resource.relatedID("version") ?? versionId,
                               locale: resource.string("locale") ?? locale, text: returned)
    }
}
