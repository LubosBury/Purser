import Foundation
import Domain

/// Promo, IAP and text cells are verified semantically (spikes S7, S10, SL10n): asc ids, customer prices, FREE_TRIAL echo
/// points, ended IAP prices, echoed start dates and text fields the write does not set do not count as differences.
enum TargetMatching {
    /// nil = not a promo, IAP or text item; the caller keeps the natural-key comparison (Reconciler.isSatisfied).
    static func promoOrIAPTargetReached(_ item: PlannedItem, live: CellState, today: CalendarDate) -> Bool? {
        switch (item.payload, item.target, live) {
        case let (.replaceIAPSchedule(target), _, .iapSchedule(liveSchedule)):
            return IAPScheduleSemantics.matches(live: liveSchedule, target: target, today: today)
        case let (.createPromo, .promo(target), .promo(liveOffer)),
             let (.replacePromoPrices, .promo(target), .promo(liveOffer)),
             let (.deletePromo, .promo(target), .promo(liveOffer)):
            return PromoPriceSemantics.matches(live: liveOffer, target: target)
        case let (.setLocalization(text), _, _):
            return LocalizationSemantics.isSatisfied(text, live: live)
        default:
            return nil
        }
    }
}
