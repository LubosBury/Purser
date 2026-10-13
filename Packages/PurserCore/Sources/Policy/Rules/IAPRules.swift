import Foundation
import Domain
import Catalog

/// L2: territories without a manual price follow the price Apple generates from the base territory.
struct L2IAPGeneratedPricesRule: PlanRule {
    let id: RuleID = "L2"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard let schedule = item.newIAPSchedule else { return nil }
            let manual = Set(schedule.manualPrices.map(\.territory)).union([schedule.baseTerritory])
            let generated = Set(context.snapshot.territories.keys).subtracting(manual).map(\.rawValue).sorted()
            return .warn(id, item.cell, "\(generated.count) territories without a manual price follow the price from the base territory \(schedule.baseTerritory) (Apple adjusts FX and taxes): \(Format.list(generated)). For the \(manual.count) manual prices, FX and taxes are the user's to watch.")
        }
    }
}

/// L3: lowering an IAP price by more than iapDecreaseC2Threshold needs C2.
struct L3IAPDecreaseRule: PlanRule {
    let id: RuleID = "L3"
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        context.items.compactMap { item -> Verdict? in
            guard item.newIAPSchedule != nil, case let .iapSchedule(old?) = item.before, case let .iapSchedule(new?) = item.target else { return nil }
            var hits: [String] = []
            for territory in Set(new.manualPrices.map(\.territory)).sorted() {
                guard let oldPrice = old.manualPrices.first(where: { $0.territory == territory && isActive($0, on: context.today) })?.customerPrice,
                      oldPrice > 0,
                      let newPrice = new.manualPrices.filter({ $0.territory == territory }).last?.customerPrice else { continue }
                let drop = (oldPrice - newPrice) / oldPrice
                if drop > AppleConstants.iapDecreaseC2Threshold { hits.append("\(territory) \(oldPrice) → \(newPrice)") }
            }
            guard !hits.isEmpty else { return nil }
            return .c2(id, item.cell, "IAP price decrease of more than \(Format.percent(AppleConstants.iapDecreaseC2Threshold)): \(Format.list(hits)).",
                       riskClass: "L3 IAP price decrease of > 30 %")
        }
    }

    private func isActive(_ price: IAPManualPrice, on day: CalendarDate) -> Bool {
        (price.startDate.map { $0 <= day } ?? true) && (price.endDate.map { day < $0 } ?? true)
    }
}
