import Foundation
import Domain
import Catalog
import Importer
import Policy

extension PlanBuilder {
    mutating func addImport(_ spec: ImportPlanSpec) throws {
        guard let mapping = context.config.importMapping else { throw PlanningError.missingImportMapping }
        if spec.table.mappingVersion != mapping.version {
            verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: nil,
                                    message: "The table is from mapping v\(spec.table.mappingVersion), the workspace has v\(mapping.version); import again."))
        }
        summary.canary = spec.canary
        let ticked = Set(spec.writeColumns.map { $0.uppercased() })
        let rows = spec.table.rows.filter { spec.filter.includes(territory: $0.territory) }.sorted { $0.territory < $1.territory }
        let targets = mapping.targets.filter { spec.filter.includes(product: $0.productAscId) }
            .sorted { (Self.kindOrder($0.kind), $0.column) < (Self.kindOrder($1.kind), $1.column) }
        for target in targets {
            let column = target.column.uppercased()
            guard target.writes && ticked.contains(column) else {
                addCheckDiffs(target, rows: rows)
                continue
            }
            switch target.kind {
            case let .regularPrice(planType):
                guard let sub = requireSubscription(target.productAscId) else { continue }
                for row in plannedRows(sub, rows, canary: spec.canary) {
                    guard let amount = row.values[column]?.amount else { continue }
                    addRegularTarget(sub, territory: row.territory, planType: planType, amount: amount,
                                     startDate: spec.startDate, preserve: spec.preserveCurrentPrice)
                }
            case .introPayUpFront, .introPayAsYouGo, .introFreeTrial:
                guard let sub = requireSubscription(target.productAscId) else { continue }
                if let nominal = target.nominalDiscount { summary.nominalDiscounts[sub.ascId] = nominal }
                for row in plannedRows(sub, rows, canary: spec.canary) {
                    addImportedIntro(sub, target: target, row: row, startDate: spec.startDate)
                }
            case let .promoPrice(offerCode):
                importPromo(target, offerCode: offerCode, rows: rows)
            case .iapManualPrice:
                importIAP(target, rows: rows, startDate: spec.startDate)
            }
        }
    }

    /// Regular prices first, so intro targets see the post-plan regular price (I4, I5).
    static func kindOrder(_ kind: TargetKind) -> Int {
        switch kind {
        case .regularPrice: return 0
        case .introPayUpFront, .introPayAsYouGo, .introFreeTrial: return 1
        case .promoPrice: return 2
        case .iapManualPrice: return 3
        }
    }

    /// Rows of the table for one subscription; CANARY keeps the first available territory.
    func plannedRows(_ sub: SubscriptionInfo, _ rows: [ImportedRow], canary: Bool) -> [ImportedRow] {
        guard canary else { return rows }
        return Array(rows.filter { sub.availableTerritories.contains($0.territory) }.prefix(1))
    }

    mutating func addImportedIntro(_ sub: SubscriptionInfo, target: ImportTarget, row: ImportedRow, startDate: CalendarDate?) {
        let column = target.column.uppercased()
        switch target.kind {
        case let .introPayUpFront(duration):
            guard let amount = row.values[column]?.amount else { return }
            addIntroTarget(sub, territory: row.territory, mode: .payUpFront, duration: duration, periods: 1, amount: .fixed(amount),
                           nominal: target.nominalDiscount, startDate: startDate, endDate: nil)
        case let .introPayAsYouGo(duration, periods):
            guard let amount = row.values[column]?.amount else { return }
            addIntroTarget(sub, territory: row.territory, mode: .payAsYouGo, duration: duration, periods: periods, amount: .fixed(amount),
                           nominal: target.nominalDiscount, startDate: startDate, endDate: nil)
        case .introFreeTrial:
            guard let duration = row.values[column]?.duration else { return }
            addIntroTarget(sub, territory: row.territory, mode: .freeTrial, duration: duration, periods: 1, amount: .free,
                           nominal: nil, startDate: startDate, endDate: nil)
        default:
            return
        }
    }

    /// Promo column: reprices an existing offer; territories without a value keep their current price.
    mutating func importPromo(_ target: ImportTarget, offerCode: String, rows: [ImportedRow]) {
        guard let offer = snapshot.promoOffers.first(where: { $0.subscriptionId == target.productAscId && $0.offerCode == offerCode }) else {
            verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: .promo(subscriptionId: target.productAscId, offerCode: offerCode),
                                    message: "The promo \(offerCode) does not exist; a new offer is created on the Promo tab."))
            return
        }
        let column = target.column.uppercased()
        var amounts: [TerritoryAmount] = []
        for row in rows { if let amount = row.values[column]?.amount { amounts.append(TerritoryAmount(territory: row.territory, amount: amount)) } }
        addPromo(PromoPlanSpec(action: .reprice(offerAscId: offer.ascId, pricing: .table(amounts))))
    }

    /// IAP column: manual prices for the listed territories on the existing base territory.
    mutating func importIAP(_ target: ImportTarget, rows: [ImportedRow], startDate: CalendarDate?) {
        guard let base = snapshot.iapSchedules[target.productAscId]?.baseTerritory else {
            verdicts.append(Verdict(rule: "L1", severity: .block(.plan), cell: .iapSchedule(iapId: target.productAscId),
                                    message: "The IAP \(target.productAscId) has no schedule with a base territory; set it on the IAP tab."))
            return
        }
        let column = target.column.uppercased()
        let prices = rows.compactMap { row in row.values[column]?.amount.map { TerritoryAmount(territory: row.territory, amount: $0) } }
        addIAP(IAPPlanSpec(iapId: target.productAscId, baseTerritory: base, prices: prices, startDate: startDate))
    }

    /// Check-only regular and intro columns: imported value after snapping vs. the live price; only differences are kept.
    mutating func addCheckDiffs(_ target: ImportTarget, rows: [ImportedRow]) {
        guard let sub = subscription(target.productAscId) else { return }
        let column = target.column.uppercased()
        for row in rows where sub.availableTerritories.contains(row.territory) {
            guard let amount = row.values[column]?.amount else { continue }
            let cell: CellKey
            let direction: SnapDirection
            let live: Decimal?
            switch target.kind {
            case let .regularPrice(planType):
                cell = .regular(subscriptionId: sub.ascId, territory: row.territory, planType: planType)
                direction = .nearest
                live = snapshot.currentRegular(subscriptionId: sub.ascId, territory: row.territory, planType: planType, on: today)?.customerPrice
            case .introPayUpFront, .introPayAsYouGo:
                cell = .intro(subscriptionId: sub.ascId, territory: row.territory, planType: .upfront)
                direction = .down
                live = snapshot.currentIntro(subscriptionId: sub.ascId, territory: row.territory, planType: .upfront, on: today)?.customerPrice
            default:
                continue
            }
            let snapped: Decimal?
            if case let .snapped(result) = snapper.snap(amount, productAscId: sub.ascId, territory: row.territory,
                                                        planType: cell.planTypeForSnap, direction: direction, cell: cell) {
                snapped = result.point.customerPrice
            } else {
                snapped = nil
            }
            if snapped != live { checkDiffs.append(CheckDiff(column: column, cell: cell, imported: amount, snapped: snapped, live: live)) }
        }
    }
}

extension CellKey {
    var planTypeForSnap: PlanType? {
        switch self {
        case let .regular(_, _, p), let .intro(_, _, p): return p
        case .promo: return .upfront
        case .iapSchedule: return nil
        }
    }
}
