import Foundation
import Domain
import ASCClient

/// L3: POST /v1/{subscription|inAppPurchase|subscriptionGroup}Versions. An assumption until spike SL10n
/// (docs/spikes/SL10n.md): 409 ENTITY_ERROR.STATE_INVALID while the owner has a pending version (editable or in review);
/// otherwise version max + 1 in PREPARE_FOR_SUBMISSION that, with `newVersionCopiesLocalizations` on, copies the Live
/// version's localizations under new ids (Apple: a new version captures "its current localized metadata"; an assumption
/// until a live trial of a new version of an approved product).
/// Version types and `ownerExists(_:)` come from FakeASC+Metadata.swift.
extension FakeASC {
    func metadataVersionKind(_ components: [String]) -> LocalizationOwnerKind? {
        guard components.count == 2, components[0] == "v1" else { return nil }
        return LocalizationOwnerKind.allCases.first { Self.versionType($0) == components[1] }
    }

    func postMetadataVersion(_ kind: LocalizationOwnerKind, _ body: Data?) throws -> FakeReply {
        let parent = WriteBodies.versionOwner(kind)
        let (data, _) = try parse(body)
        guard data["type"] as? String == Self.versionType(kind), let ownerId = relId(data, parent.relationship) else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.REQUIRED", "The relationship '\(parent.relationship)' is required")
        }
        let owner = LocalizationOwner(kind, ownerId)
        guard ownerExists(owner) else { throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The \(parent.relationship) does not exist") }
        let versions = model.versions.filter { $0.owner == owner }
        let known = OwnerMetadata(owner: owner, versions: versions.map {
            MetadataVersion(ascId: $0.id, owner: owner, number: $0.number, state: $0.state)
        }, localizations: [])
        if let pending = known.pendingVersion {
            throw conflict("ENTITY_ERROR.STATE_INVALID",
                           "Version \(pending.number) is \(pending.state.rawValue); only one version that is not approved can exist")
        }
        let created = FakeVersion(id: nextId("version"), owner: owner, number: (versions.map(\.number).max() ?? 0) + 1,
                                  state: .prepareForSubmission)
        model.versions.append(created)
        if newVersionCopiesLocalizations, let live = known.liveVersion {
            let liveRows = model.localizations.filter { $0.versionId == live.ascId }
            for row in liveRows {
                model.localizations.append(FakeLocalization(id: nextId("loc"), versionId: created.id, locale: row.locale, text: row.text))
            }
        }
        return FakeReply(status: 201, body: single(resource(Self.versionType(kind), created.id,
                                                           attributes: ["version": .int(created.number), "state": .string(created.state.rawValue)],
                                                           relationships: [parent.relationship: rel(parent.type, owner.ascId)])),
                         applied: true)
    }
}
