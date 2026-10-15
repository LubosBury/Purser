import Foundation
import Domain

/// L3: a new subscription, in-app purchase or group version, the item behind rule N5. The version type comes from
/// WriteBodies.versionType; AppGuard.versionParents checks the same relationship and type.
extension WritePaths {
    package static func metadataVersion(_ kind: LocalizationOwnerKind) -> (method: String, path: String) {
        ("POST", "/v1/\(WriteBodies.versionType(kind))")
    }
}

extension WriteBodies {
    /// The relationship that names the owner, and the owner's type (OpenAPI 4.5.1, *VersionCreateRequest).
    package static func versionOwner(_ kind: LocalizationOwnerKind) -> (relationship: String, type: String) {
        switch kind {
        case .subscription: return ("subscription", "subscriptions")
        case .iap: return ("inAppPurchase", "inAppPurchases")
        case .group: return ("subscriptionGroup", "subscriptionGroups")
        }
    }

    /// SubscriptionVersionCreateRequest, InAppPurchaseVersionCreateRequest, SubscriptionGroupVersionCreateRequest carry no
    /// attributes, only the owner.
    package static func createMetadataVersion(owner: LocalizationOwner) -> JSONBody {
        let parent = versionOwner(owner.kind)
        return .object(["data": .object([
            "type": .string(versionType(owner.kind)),
            "relationships": .object([parent.relationship: ref(parent.type, owner.ascId)]),
        ])])
    }
}

extension WriteResponses {
    /// The created version. Without a `version` number or a `state` the answer is a decoding error, so the Executor reads the
    /// owner (maybeApplied) instead of trusting it.
    package static func metadataVersion(_ document: JSONAPIDocument?, owner: LocalizationOwner) throws -> MetadataVersion {
        let resource = try primary(document, type: WriteBodies.versionType(owner.kind))
        guard let number = resource.int("version"), let state = resource.string("state") else {
            throw ASCError.decoding("\(resource.type) \(resource.id): version or state is missing")
        }
        return MetadataVersion(ascId: resource.id, owner: owner, number: number, state: MetadataVersionState(state))
    }
}
