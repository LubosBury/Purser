import Foundation

/// What a localization cell means for the Reconciler, verification, outcomes and the plan diff.
public enum LocalizationSemantics {
    /// What customers will see after the pending version is approved: the pending row when a pending version exists, else live.
    public static func effectiveText(_ state: CellState) -> LocalizationText? {
        guard case let .localization(live, pending, pendingVersion) = state else { return nil }
        return pendingVersion != nil ? pending?.text : live?.text
    }

    /// Reconciler "before" check: same effective text, and the pending version did not move on (into review, or approved).
    /// An `expected` with a pending version needs that same version, by id, still pending: a text planned into a version
    /// that was approved and followed by a new one does not match, even when the new one holds a copy of its texts, so
    /// the item never writes into a version that is no longer in preparation. An `expected` without a pending version (only
    /// Live) still matches a new version that copied the live texts (a version the plan created, or Apple's copy); only the
    /// version id is compared, never a row id.
    public static func matches(live: CellState, expected: CellState) -> Bool {
        if matchesMissingCopy(live: live, expected: expected) { return true }
        guard case let .localization(_, _, liveVersion) = live, case let .localization(_, _, expectedVersion) = expected else { return false }
        if let expectedVersion, liveVersion?.ascId != expectedVersion.ascId { return false }
        if expectedVersion?.state.role == .editable, liveVersion?.state.role != .editable { return false }
        if liveVersion?.state.role == .inReview, expectedVersion?.state.role != .inReview { return false }
        return effectiveText(live) == effectiveText(expected)
    }

    /// Target reached: the pending version is editable and its row for the locale carries every non-nil field of `s.text`.
    public static func isSatisfied(_ s: SetLocalization, live: CellState) -> Bool {
        guard case let .localization(_, pending?, version?) = live, version.state.role == .editable,
              pending.owner == s.owner, pending.locale == s.locale else { return false }
        return carries(pending.text, s.text)
    }

    /// createMetadataVersion reached: the owner has a pending version with role .editable.
    public static func versionExists(_ live: CellState) -> Bool {
        switch live {
        case let .metadataVersion(version?), let .localization(_, _, version?):
            return version.state.role == .editable
        default:
            return false
        }
    }

    /// `text` has the name of `wanted` and every description and custom app name `wanted` sets; nil fields of `wanted` are not compared.
    public static func carries(_ text: LocalizationText?, _ wanted: LocalizationText) -> Bool {
        guard let text else { return false }
        return text.name == wanted.name
            && (wanted.description.map { $0 == text.description } ?? true)
            && (wanted.customAppName.map { $0 == text.customAppName } ?? true)
    }
}
