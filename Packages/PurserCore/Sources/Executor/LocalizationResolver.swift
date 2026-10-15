import Foundation
import Domain

/// The request a SET_TEXT item sends.
package enum LocalizationRequest: Hashable, Sendable {
    case create(versionId: String)
    case update(localizationId: String)
}

package enum LocalizationResolverError: Error, Equatable, Sendable {
    /// Neither id is known and no createMetadataVersion item of the owner created a version in this plan.
    case noVersion(LocalizationOwner)
    /// The owner read does not show the version this plan created yet (a read right after the POST may miss it). Nothing
    /// is sent: the item waits and reads again, so a copied locale is never POSTed into a version the read does not show.
    case versionNotVisible(LocalizationOwner, versionId: String)
}

package enum LocalizationResolver {
    /// localizationId -> update; versionId -> create; both nil -> the version a done createMetadataVersion item of the
    /// same owner created in this plan (`createdVersions`), then the locale's row in `fresh` (one read per owner and run).
    /// Runs in the caller's isolation, so `fresh` may read through the caller's state.
    package static func resolve(_ s: SetLocalization, createdVersions: [LocalizationOwner: String],
                                isolation: isolated (any Actor)? = #isolation,
                                fresh: () async throws -> OwnerMetadata) async throws -> LocalizationRequest {
        if let id = s.localizationId { return .update(localizationId: id) }
        if let id = s.versionId { return .create(versionId: id) }
        guard let versionId = createdVersions[s.owner] else { throw LocalizationResolverError.noVersion(s.owner) }
        let metadata = try await fresh()
        try requireVersion(versionId, in: metadata)
        if let row = metadata.localizations.first(where: { $0.versionId == versionId && $0.locale == s.locale }) {
            return .update(localizationId: row.ascId)
        }
        return .create(versionId: versionId)
    }

    /// Throws `versionNotVisible` unless `metadata` lists the version `versionId`.
    package static func requireVersion(_ versionId: String, in metadata: OwnerMetadata) throws {
        guard metadata.versions.contains(where: { $0.ascId == versionId }) else {
            throw LocalizationResolverError.versionNotVisible(metadata.owner, versionId: versionId)
        }
    }
}
