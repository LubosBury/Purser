import Foundation
import Domain
import ASCClient

/// Versions and their texts (ASC API 4.4.1). Reads only; writes of texts and versions are not modelled yet.
extension FakeASC {
    static func versionType(_ kind: LocalizationOwnerKind) -> String {
        switch kind {
        case .subscription: return "subscriptionVersions"
        case .iap: return "inAppPurchaseVersions"
        case .group: return "subscriptionGroupVersions"
        }
    }

    static func localizationType(_ kind: LocalizationOwnerKind) -> String {
        switch kind {
        case .subscription: return "subscriptionLocalizations"
        case .iap: return "inAppPurchaseLocalizations"
        case .group: return "subscriptionGroupLocalizations"
        }
    }

    func ownerExists(_ owner: LocalizationOwner) -> Bool {
        switch owner.kind {
        case .subscription: return model.subscriptions.contains { $0.id == owner.ascId }
        case .iap: return model.iaps.contains { $0.id == owner.ascId }
        case .group: return model.groups.contains { $0.id == owner.ascId }
        }
    }

    func localizationResource(_ row: FakeLocalization, kind: LocalizationOwnerKind) -> JSONBody {
        var attributes: [String: JSONBody] = ["name": .string(row.text.name), "locale": .string(row.locale)]
        switch kind {
        case .group: attributes["customAppName"] = row.text.customAppName.map(JSONBody.string) ?? .null
        case .subscription, .iap: attributes["description"] = row.text.description.map(JSONBody.string) ?? .null
        }
        return resource(Self.localizationType(kind), row.id, attributes: attributes)
    }

    /// One version. With include=localizations its relationship lists at most `includeLimit` ids, sorted by locale, and the
    /// same texts come as included resources (ASC caps an include with limit[localizations], at most 50).
    func versionEntry(_ version: FakeVersion, includeLimit: Int?) -> (resource: JSONBody, included: [String: JSONBody]) {
        var relationships: [String: JSONBody] = [:]
        var included: [String: JSONBody] = [:]
        if let includeLimit {
            let rows = model.localizations.filter { $0.versionId == version.id }.sorted { $0.locale < $1.locale }.prefix(includeLimit)
            relationships["localizations"] = .object(["data": .array(rows.map { ident(Self.localizationType(version.owner.kind), $0.id) })])
            for row in rows { included["localizations|\(row.id)"] = localizationResource(row, kind: version.owner.kind) }
        }
        return (resource(Self.versionType(version.owner.kind), version.id,
                         attributes: ["version": .int(version.number), "state": .string(version.state.rawValue)],
                         relationships: relationships), included)
    }

    /// GET .../versions of a subscription, IAP or group and GET /v1/<kind>Versions/{id}/localizations; nil for any other path.
    func handleMetadataRead(_ c: [String], url: URL, query: [String: String]) throws -> FakeReply? {
        let ok = { (body: JSONBody) in FakeReply(status: 200, body: body, applied: false) }
        let lists: [(pattern: [String], kind: LocalizationOwnerKind)] = [
            (["v1", "subscriptions", "*", "versions"], .subscription),
            (["v2", "inAppPurchases", "*", "versions"], .iap),
            (["v1", "subscriptionGroups", "*", "versions"], .group),
        ]
        for (pattern, kind) in lists {
            guard let id = capture(c, pattern) else { continue }
            let owner = LocalizationOwner(kind, id)
            guard ownerExists(owner) else { throw notFound() }
            let includesTexts = (query["include"] ?? "").split(separator: ",").contains("localizations")
            let includeLimit = includesTexts ? min(Int(query["limit[localizations]"] ?? "") ?? 50, 50) : nil
            let versions = model.versions.filter { $0.owner == owner }.sorted { $0.number < $1.number }
            return ok(page(versions.map { versionEntry($0, includeLimit: includeLimit) }, url: url, query: query))
        }
        for kind in LocalizationOwnerKind.allCases {
            guard let id = capture(c, ["v1", Self.versionType(kind), "*", "localizations"]) else { continue }
            guard model.versions.contains(where: { $0.id == id && $0.owner.kind == kind }) else { throw notFound() }
            let rows = model.localizations.filter { $0.versionId == id }.sorted { $0.locale < $1.locale }
            return ok(page(rows.map { (localizationResource($0, kind: kind), [:]) }, url: url, query: query))
        }
        return nil
    }
}
