import Foundation
import CryptoKit
import Domain
import Store
import Catalog

extension ItemEffectiveness {
    /// Effective judged from a synced snapshot (reconcileAfterSync).
    public static func inSnapshot(_ stored: StoredItem, snapshot: CatalogSnapshot, today: CalendarDate) -> Bool {
        switch stored.item.payload {
        case let .createRegularPrice(p):
            guard dayAfter(p.startDate, today), let id = stored.ascId else { return false }
            return snapshot.currentRegular(subscriptionId: p.subscriptionId, territory: p.territory, planType: p.planType, on: today)?.ascId == id
        case let .createIntro(o):
            guard dayAfter(o.startDate, today), let id = stored.ascId else { return false }
            guard let row = snapshot.introRows.first(where: { $0.ascId == id }) else { return o.endDate.map { $0 <= today } ?? false }
            return row.isActive(on: today) || (row.endDate.map { $0 <= today } ?? false)
        case let .endIntro(id, end):
            guard end.adding(days: 1) <= today else { return false }
            return snapshot.introRows.first(where: { $0.ascId == id }).map { $0.endDate == end } ?? true
        case let .deleteRegularPrice(id):
            return !snapshot.regularRows.contains { $0.ascId == id }
        case let .deleteIntro(id):
            return !snapshot.introRows.contains { $0.ascId == id }
        case let .deletePromo(id):
            return !snapshot.promoOffers.contains { $0.ascId == id }
        case .createPromo, .replacePromoPrices, .replaceIAPSchedule:
            return stored.verifiedAt != nil
        }
    }

    /// Whether what the item wrote is still visible; false = it vanished (SCHEDULE_BROKEN unless a Purser item explains it).
    public static func stillPresent(_ stored: StoredItem, snapshot: CatalogSnapshot, today: CalendarDate) -> Bool {
        switch stored.item.payload {
        case .createRegularPrice:
            guard let id = stored.ascId else { return false }
            return snapshot.regularRows.contains { $0.ascId == id }
        case .createIntro:
            guard let id = stored.ascId else { return false }
            return snapshot.introRows.contains { $0.ascId == id }
        case let .endIntro(id, end):
            guard let row = snapshot.introRows.first(where: { $0.ascId == id }) else { return end <= today }
            return row.endDate == end
        case let .createPromo(o):
            return snapshot.promoOffers.contains { $0.subscriptionId == o.subscriptionId && $0.offerCode == o.offerCode }
        case let .replacePromoPrices(id, _):
            guard let offer = snapshot.promoOffers.first(where: { $0.ascId == id }) else { return false }
            return Reconciler.reached(stored.item, live: .promo(offer), today: today)
        case let .replaceIAPSchedule(s):
            return Reconciler.reached(stored.item, live: .iapSchedule(snapshot.iapSchedules[s.iapId]), today: today)
        case .deleteRegularPrice, .deleteIntro, .deletePromo:
            return true
        }
    }
}

extension OutcomeCalculator {
    /// A Scheduled plan after a sync; nil = no change.
    public static func afterSync(_ items: [StoredItem]) -> (state: PlanState, endReason: PlanEndReason?)? {
        let counted = items.filter { $0.state != .superseded && $0.state != .withdrawn }
        if counted.isEmpty { return (.cancelled, items.contains { $0.state == .withdrawn } ? .withdrawn : .superseded) }
        if counted.contains(where: { $0.state == .mismatch }) { return (.partiallyApplied, nil) }
        if counted.allSatisfy({ $0.state == .effective }) { return (.effective, nil) }
        return nil
    }
}

/// K9 planHash: sha256 over JSONCoding of the items.
enum PlanHasher {
    static func hash(_ items: [PlannedItem]) throws -> String {
        let json = try JSONCoding.string(items)
        return SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Build recorded into drafts the Executor creates (replan, withdraw).
enum BuildInfo {
    static var current: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        return "\(version) (\(build))"
    }
}
