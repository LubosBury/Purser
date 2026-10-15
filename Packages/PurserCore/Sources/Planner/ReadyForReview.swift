import Foundation
import Domain
import Store

/// L3: the owners whose new version a plan created. Purser never submits a version for review; the owner does it in
/// App Store Connect, and the Plan screen and the MCP tools say so.
public enum ReadyForReview {
    public static let callToAction = "Ready for review: submit in App Store Connect"
    /// A version whose texts did not all land must not be submitted as it is. MCP wording (names the tool); the Plan screen
    /// names its own button instead.
    public static let incompleteMessage = "Not ready: some texts were not written; replan the rest first (replan_rest)."

    /// The owners of a finished plan's written versions that still wait in preparation, sorted: `ready` when every text the
    /// plan has for the owner is in the version, `incomplete` otherwise.
    public struct Status: Equatable, Sendable {
        public var ready: [LocalizationOwner]
        public var incomplete: [LocalizationOwner]
        public init(ready: [LocalizationOwner], incomplete: [LocalizationOwner]) {
            self.ready = ready
            self.incomplete = incomplete
        }
    }

    /// Plan states after an apply has ended.
    static let finished: Set<PlanState> = [.scheduled, .effective, .partiallyApplied, .closed]
    static let written: Set<ItemState> = [.done, .effective]

    /// Per Done or Effective createMetadataVersion item of a finished plan: the version with the item's asc_id must still be
    /// in `metadata` (the latest snapshot) with role .editable, otherwise the owner is in neither list (in review or approved:
    /// the call to action no longer applies; not in the snapshot yet: nothing is known). A SET_TEXT item of the owner that is
    /// Done or Effective has landed (a later change by another plan is a newer decision); every other one must be satisfied
    /// by the snapshot's cell (LocalizationSemantics.isSatisfied), so a text a later plan (`replan_rest`) wrote counts.
    /// Ready when all texts landed, incomplete otherwise.
    public static func status(plan: StoredPlan, items: [StoredItem], metadata: [LocalizationOwner: OwnerMetadata]) -> Status {
        guard finished.contains(plan.state) else { return Status(ready: [], incomplete: []) }
        var ready: Set<LocalizationOwner> = []
        var incomplete: Set<LocalizationOwner> = []
        for stored in items where written.contains(stored.state) {
            guard case let .createMetadataVersion(owner) = stored.item.payload, let versionId = stored.ascId, !versionId.isEmpty,
                  let known = metadata[owner],
                  known.versions.contains(where: { $0.ascId == versionId && $0.state.role == .editable }) else { continue }
            let unwritten = items.compactMap { item -> SetLocalization? in
                guard !written.contains(item.state), case let .setLocalization(s) = item.item.payload, s.owner == owner else { return nil }
                return s
            }
            if unwritten.allSatisfy({ LocalizationSemantics.isSatisfied($0, live: known.localizationCell(locale: $0.locale)) }) {
                ready.insert(owner)
            } else {
                incomplete.insert(owner)
            }
        }
        return Status(ready: ready.sorted(), incomplete: incomplete.sorted())
    }

    /// The owners whose version waits for the owner's submission (`status(...).ready`).
    public static func owners(plan: StoredPlan, items: [StoredItem], metadata: [LocalizationOwner: OwnerMetadata]) -> [LocalizationOwner] {
        status(plan: plan, items: items, metadata: metadata).ready
    }
}
