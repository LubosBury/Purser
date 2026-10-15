import Foundation

extension LocalizationSemantics {
    /// While AppleConstants.newVersionCopiesLocalizations is false (no live trial of a new version of an approved product has
    /// shown yet that Apple copies the Live texts into it), a pending editable version that appeared after planning and has
    /// no row for the locale still matches a "before" planned without a pending version, as long as the Live row is the
    /// same. The text item then POSTs its full text into the new version. Once copying is confirmed, a missing row is a
    /// change and the item goes Stale.
    /// A copy of the Live text already matches through `matches`.
    public static func matchesMissingCopy(live: CellState, expected: CellState,
                                          copiesLocalizations: Bool = AppleConstants.newVersionCopiesLocalizations) -> Bool {
        guard !copiesLocalizations,
              case let .localization(liveRow, livePending, liveVersion) = live,
              case let .localization(expectedRow, expectedPending, expectedVersion) = expected,
              expectedVersion == nil, expectedPending == nil, livePending == nil,
              liveVersion?.state.role == .editable else { return false }
        return liveRow == expectedRow
    }

    /// The text `s` writes is exactly the Live text of its locale in `before`: a Live text carried over unchanged into a new
    /// version. App Store Connect accepted that text already; it changes nothing customers see.
    public static func carriesLiveText(_ s: SetLocalization, before: CellState) -> Bool {
        guard case let .localization(live?, _, _) = before else { return false }
        return live.text == s.text
    }
}
