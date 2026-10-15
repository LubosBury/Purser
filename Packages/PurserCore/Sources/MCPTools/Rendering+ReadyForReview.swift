import Foundation
import Domain
import Planner
import MCPBridge

extension MCPRender {
    /// L3: the owners whose new version waits for submission in App Store Connect, with the call to action; nil when none.
    public static func readyForReview(_ owners: [LocalizationOwner], ownerName: (LocalizationOwner) -> String) -> JSONValue? {
        versionOwners(owners, message: ReadyForReview.callToAction, ownerName: ownerName)
    }

    /// L3: the owners whose new version exists but not all of whose texts were written; nil when none.
    public static func incompleteVersions(_ owners: [LocalizationOwner], ownerName: (LocalizationOwner) -> String) -> JSONValue? {
        versionOwners(owners, message: ReadyForReview.incompleteMessage, ownerName: ownerName)
    }

    private static func versionOwners(_ owners: [LocalizationOwner], message: String, ownerName: (LocalizationOwner) -> String) -> JSONValue? {
        guard !owners.isEmpty else { return nil }
        return ["message": .string(message),
                "owners": .array(owners.map { owner -> JSONValue in
                    ["kind": .string(readyForReviewKind(owner.kind)), "asc_id": .string(owner.ascId), "name": .string(ownerName(owner))]
                })]
    }

    private static func readyForReviewKind(_ kind: LocalizationOwnerKind) -> String {
        switch kind {
        case .subscription: return "subscription"
        case .iap: return "in_app_purchase"
        case .group: return "subscription_group"
        }
    }
}
