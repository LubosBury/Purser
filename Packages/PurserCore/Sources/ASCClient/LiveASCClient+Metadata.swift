import Foundation
import Domain

extension LiveASCClient {
    /// `limit[localizations]`: ASC includes at most this many texts per version.
    static let localizationIncludeLimit = 50

    /// GET only. One versions read per owner; a live or pending version whose relationship lists exactly
    /// `localizationIncludeLimit` ids may have more texts, so its texts are read again in full.
    public func metadata(owner: LocalizationOwner) async throws -> OwnerMetadata {
        let pages = try await http.getAll(ASCPath.versions(of: owner), query: [
            URLQueryItem(name: "include", value: "localizations"),
            URLQueryItem(name: "limit[localizations]", value: String(Self.localizationIncludeLimit)),
            URLQueryItem(name: "limit", value: "200"),
        ])
        var metadata = try ASCMapping.ownerMetadata(pages, owner: owner)
        let kept = Set([metadata.liveVersion, metadata.pendingVersion].compactMap { $0?.ascId })
        for versionId in ASCMapping.truncatedVersionIds(pages, limit: Self.localizationIncludeLimit) where kept.contains(versionId) {
            await http.appGuard.allowChildren([versionId])
            let textPages = try await http.getAll(ASCPath.versionLocalizations(owner.kind, version: versionId),
                                                  query: [URLQueryItem(name: "limit", value: "200")])
            let rows = try ASCMapping.localizations(textPages.flatMap(\.data), owner: owner, versionId: versionId)
            metadata = OwnerMetadata(owner: owner, versions: metadata.versions,
                                     localizations: metadata.localizations.filter { $0.versionId != versionId } + rows)
        }
        await http.appGuard.allowChildren(Set(metadata.versions.map(\.ascId) + metadata.localizations.map(\.ascId)))
        return metadata
    }
}

extension ASCMapping {
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

    /// Every version of `owner` and the texts of its live and pending versions, from the pages of GET .../versions with
    /// include=localizations. The version number is the attribute `version`; texts of retired versions are dropped.
    static func ownerMetadata(_ pages: [JSONAPIDocument], owner: LocalizationOwner) throws -> OwnerMetadata {
        let resources = pages.flatMap(\.data)
        let versions = try resources.map { try version($0, owner: owner) }
        let shell = OwnerMetadata(owner: owner, versions: versions, localizations: [])
        let kept = Set([shell.liveVersion, shell.pendingVersion].compactMap { $0?.ascId })
        var rows: [LocalizationRow] = []
        for resource in resources where kept.contains(resource.id) {
            let texts = try (resource.relationships["localizations"]?.data ?? []).map { link -> JSONAPIResource in
                guard let text = pages.lazy.compactMap({ $0.includedResource(type: localizationType(owner.kind), id: link.id) }).first else {
                    throw ASCError.decoding("\(resource.type) \(resource.id): localization \(link.id) not included")
                }
                return text
            }
            rows += try localizations(texts, owner: owner, versionId: resource.id)
        }
        return OwnerMetadata(owner: owner, versions: versions, localizations: rows)
    }

    static func version(_ resource: JSONAPIResource, owner: LocalizationOwner) throws -> MetadataVersion {
        guard resource.type == versionType(owner.kind) else {
            throw ASCError.decoding("\(resource.type) \(resource.id): not a version of \(owner)")
        }
        guard let number = resource.int("version"), let state = resource.string("state") else {
            throw ASCError.decoding("\(resource.type) \(resource.id): missing version or state")
        }
        return MetadataVersion(ascId: resource.id, owner: owner, number: number, state: MetadataVersionState(state))
    }

    /// V2 localizations: `name`, `locale` and `description` (subscription, IAP) or `customAppName` (group).
    static func localizations(_ resources: [JSONAPIResource], owner: LocalizationOwner, versionId: String) throws -> [LocalizationRow] {
        try resources.map { resource in
            guard resource.type == localizationType(owner.kind), let locale = resource.string("locale"), !locale.isEmpty else {
                throw ASCError.decoding("\(resource.type) \(resource.id): not a localization of \(owner) or missing locale")
            }
            let name = resource.string("name") ?? ""
            let text = owner.kind == .group
                ? LocalizationText(name: name, customAppName: resource.string("customAppName"))
                : LocalizationText(name: name, description: resource.string("description"))
            return LocalizationRow(ascId: resource.id, owner: owner, versionId: versionId, locale: locale, text: text)
        }
    }

    /// Versions whose `localizations` relationship lists exactly `limit` ids: the include may have cut their texts.
    static func truncatedVersionIds(_ pages: [JSONAPIDocument], limit: Int) -> [String] {
        pages.flatMap(\.data).filter { $0.relationships["localizations"]?.data?.count == limit }.map(\.id)
    }
}
