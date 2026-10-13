import Foundation
import Domain
import Store

public enum ItemEffectiveness {
    /// True when `start` (nil = immediately) plus one day (later APAC start, T1-17) is not after `today`.
    static func dayAfter(_ start: CalendarDate?, _ today: CalendarDate) -> Bool {
        start.map { $0.adding(days: 1) <= today } ?? true
    }

    /// Effective as soon as verify confirmed it: promo, IAP and deletes always; POST and PATCH_END only once their date passed.
    public static func immediately(_ item: PlannedItem, today: CalendarDate) -> Bool {
        switch item.payload {
        case .createPromo, .replacePromoPrices, .deletePromo, .replaceIAPSchedule, .deleteRegularPrice, .deleteIntro:
            return true
        case let .createRegularPrice(p):
            return dayAfter(p.startDate, today)
        case let .createIntro(o):
            return dayAfter(o.startDate, today)
        case let .endIntro(_, end):
            return end.adding(days: 1) <= today
        }
    }
}

public enum OutcomeCalculator {
    static let written: Set<ItemState> = [.done, .mismatch, .effective, .superseded, .withdrawn]
    static let unfinished: Set<ItemState> = [.failed, .stale, .skipped, .mismatch, .pending, .inFlight]

    /// Plan state when the write loop has processed every item (spec §6 "Plan states").
    public static func afterApply(_ items: [StoredItem]) -> PlanState {
        let counted = items.filter { $0.state != .superseded && $0.state != .withdrawn }
        let wrote = items.contains { written.contains($0.state) }
        let incomplete = counted.contains { unfinished.contains($0.state) }
        if !wrote { return incomplete ? .stale : .effective }
        if incomplete { return .partiallyApplied }
        return counted.allSatisfy { $0.state == .effective } ? .effective : .scheduled
    }
}
