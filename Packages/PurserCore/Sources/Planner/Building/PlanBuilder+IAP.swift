import Foundation
import Domain
import Catalog

extension PlanBuilder {
    /// L1: the whole schedule is always sent: base territory, every manual price including existing future ones.
    mutating func addIAP(_ spec: IAPPlanSpec) {
        guard snapshot.iaps[spec.iapId] != nil else {
            verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: nil, message: "The IAP \(spec.iapId) is not in the catalog."))
            return
        }
        let cell: CellKey = .iapSchedule(iapId: spec.iapId)
        let existing = snapshot.iapSchedules[spec.iapId]
        var newPoints: [TerritoryCode: PricePoint] = [:]
        for price in spec.prices.sorted(by: { $0.territory < $1.territory }) {
            if let point = snap(price.amount, product: spec.iapId, territory: price.territory, planType: nil, direction: .nearest, cell: cell) {
                newPoints[price.territory] = point
            }
        }
        var rows: [IAPManualPrice] = []
        let territories = Set(newPoints.keys).union(existing?.manualPrices.map(\.territory) ?? []).sorted()
        for territory in territories {
            let old = (existing?.manualPrices ?? []).filter { $0.territory == territory && ($0.endDate.map { $0 > today } ?? true) }
            let current = old.first { $0.startDate.map { $0 <= today } ?? true }
            let future = old.filter { $0.startDate.map { $0 > today } ?? false }.sorted { $0.startDate! < $1.startDate! }
            guard let point = newPoints[territory] else {
                if let current { rows.append(IAPManualPrice(ascId: nil, territory: territory, pricePointId: current.pricePointId, startDate: nil, endDate: current.endDate, customerPrice: current.customerPrice)) }
                rows += future.map { IAPManualPrice(ascId: nil, territory: territory, pricePointId: $0.pricePointId, startDate: $0.startDate, endDate: $0.endDate, customerPrice: $0.customerPrice) }
                continue
            }
            if let start = spec.startDate, start > today {
                if let current {
                    rows.append(IAPManualPrice(ascId: nil, territory: territory, pricePointId: current.pricePointId, startDate: nil,
                                               endDate: min(current.endDate ?? start, start), customerPrice: current.customerPrice))
                }
                for row in future where row.startDate! < start {
                    rows.append(IAPManualPrice(ascId: nil, territory: territory, pricePointId: row.pricePointId, startDate: row.startDate,
                                               endDate: min(row.endDate ?? start, start), customerPrice: row.customerPrice))
                }
                let later = future.filter { $0.startDate! > start }
                rows.append(IAPManualPrice(ascId: nil, territory: territory, pricePointId: point.id, startDate: start,
                                           endDate: later.first?.startDate, customerPrice: point.customerPrice))
                rows += later.map { IAPManualPrice(ascId: nil, territory: territory, pricePointId: $0.pricePointId, startDate: $0.startDate, endDate: $0.endDate, customerPrice: $0.customerPrice) }
            } else {
                rows.append(IAPManualPrice(ascId: nil, territory: territory, pricePointId: point.id, startDate: nil,
                                           endDate: future.first?.startDate, customerPrice: point.customerPrice))
                rows += future.map { IAPManualPrice(ascId: nil, territory: territory, pricePointId: $0.pricePointId, startDate: $0.startDate, endDate: $0.endDate, customerPrice: $0.customerPrice) }
            }
        }
        guard rows.contains(where: { $0.territory == spec.baseTerritory }) else {
            verdicts.append(Verdict(rule: "L1", severity: .block(.plan), cell: cell, message: "The base territory \(spec.baseTerritory) has no manual price."))
            return
        }
        // The replaced schedule is a row the plan creates: scheduleId nil (K9 placeholder convention).
        let target = IAPSchedule(iapId: spec.iapId, scheduleId: nil, baseTerritory: spec.baseTerritory, manualPrices: rows)
        func shape(_ s: IAPSchedule?) -> [String] {
            guard let s else { return [] }
            return [s.baseTerritory.rawValue] + s.manualPrices.map { price in
                let start = price.startDate.map { $0 > today ? $0.iso : "-" } ?? "-"
                return "\(price.territory):\(price.pricePointId):\(start):\(price.endDate?.iso ?? "-")"
            }.sorted()
        }
        if shape(existing) == shape(target) { return }
        let payload = NewIAPSchedule(iapId: spec.iapId, baseTerritory: spec.baseTerritory, manualPrices: rows.map {
            NewIAPManualPrice(territory: $0.territory, pricePointId: $0.pricePointId, startDate: $0.startDate, endDate: $0.endDate)
        })
        sink.add(cell, .replaceIAPSchedule(payload), before: .iapSchedule(existing), target: .iapSchedule(target), rules: ["L1", "L2"])
    }
}
