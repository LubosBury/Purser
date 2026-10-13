import Foundation
import Domain
import Catalog
import Store
import Policy
import Planner
import MCPBridge

/// Catalog, findings and plans as the JSON the MCP tools return. Amounts are in the territory's own currency.
public enum MCPRender {
    /// Through the decimal text: NSDecimalNumber.doubleValue can be one ulp off (34.99 -> 34.990000000000002).
    public static func number(_ value: Decimal) -> JSONValue {
        .number(Double(NSDecimalNumber(decimal: value).stringValue) ?? NSDecimalNumber(decimal: value).doubleValue)
    }
    public static func number(_ value: Int) -> JSONValue { .number(Double(value)) }
    public static func timestamp(_ date: Date) -> JSONValue { .string(ISO8601DateFormatter().string(from: date)) }

    private static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    private static func optional(_ value: Decimal?) -> JSONValue { value.map(number) ?? .null }
    private static func optional(_ value: CalendarDate?) -> JSONValue { value.map { .string($0.iso) } ?? .null }

    // MARK: Catalog

    public static func products(_ snapshot: CatalogSnapshot) -> JSONValue {
        let subscriptions = snapshot.subscriptions.values.sorted { ($0.groupName, $0.name) < ($1.groupName, $1.name) }.map { sub -> JSONValue in
            ["asc_id": .string(sub.ascId), "product_id": .string(sub.productId), "name": .string(sub.name),
             "period": .string(sub.period.rawValue), "state": .string(sub.state.rawValue), "group": .string(sub.groupName),
             "territories": number(sub.availableTerritories.count), "monthly_plan_available": .bool(sub.monthlyPlanAvailable)]
        }
        let iaps = snapshot.iaps.values.sorted { $0.name < $1.name }.map { iap -> JSONValue in
            ["asc_id": .string(iap.ascId), "product_id": .string(iap.productId), "name": .string(iap.name),
             "type": .string(iap.iapType), "state": .string(iap.state.rawValue)]
        }
        return ["catalog_read_at": timestamp(snapshot.takenAt), "subscriptions": .array(subscriptions), "in_app_purchases": .array(iaps)]
    }

    /// Prices of one product (ASC id); nil when the snapshot has no such product.
    public static func prices(productAscId: String, snapshot: CatalogSnapshot, territories: Set<TerritoryCode>?, today: CalendarDate) -> JSONValue? {
        if let subscription = snapshot.subscriptions[productAscId] {
            return subscriptionPrices(subscription, snapshot: snapshot, territories: territories, today: today)
        }
        if let iap = snapshot.iaps[productAscId] {
            return iapPrices(iap, snapshot: snapshot, territories: territories)
        }
        return nil
    }

    private static func subscriptionPrices(_ subscription: SubscriptionInfo, snapshot: CatalogSnapshot, territories: Set<TerritoryCode>?,
                                           today: CalendarDate) -> JSONValue {
        let planTypes: [PlanType] = subscription.monthlyPlanAvailable ? [.upfront, .monthly] : [.upfront]
        var rows: [JSONValue] = []
        for territory in snapshot.territories.keys.sorted() where territories?.contains(territory) ?? true {
            for planType in planTypes {
                let current = snapshot.currentRegular(subscriptionId: subscription.ascId, territory: territory, planType: planType, on: today)
                let scheduled = snapshot.scheduledRegular(subscriptionId: subscription.ascId, territory: territory, planType: planType, on: today)
                let intro = snapshot.currentIntro(subscriptionId: subscription.ascId, territory: territory, planType: planType, on: today)
                let futureIntro = snapshot.futureIntro(subscriptionId: subscription.ascId, territory: territory, planType: planType, on: today)
                guard current != nil || scheduled != nil || intro != nil || futureIntro != nil else { continue }
                var row: [String: JSONValue] = ["territory": .string(territory.rawValue),
                                                "currency": optional(snapshot.territories[territory]?.rawValue),
                                                "price": optional(current?.customerPrice)]
                if subscription.monthlyPlanAvailable { row["plan_type"] = .string(planType.rawValue) }
                if let scheduled {
                    row["scheduled_price"] = number(scheduled.customerPrice)
                    row["scheduled_from"] = optional(scheduled.startDate)
                    row["scheduled_preserves_current_price"] = .bool(scheduled.preserved)
                }
                if let intro { row["intro_offer"] = introOffer(intro) }
                if let futureIntro { row["future_intro_offer"] = introOffer(futureIntro) }
                rows.append(.object(row))
            }
        }
        let offers = snapshot.promoOffers(subscriptionId: subscription.ascId).map { offer -> JSONValue in
            let prices = offer.prices.filter { territories?.contains($0.territory) ?? true }.map { price -> JSONValue in
                ["territory": .string(price.territory.rawValue), "price": optional(price.customerPrice)]
            }
            return ["offer_id": .string(offer.ascId), "offer_code": .string(offer.offerCode), "name": .string(offer.name),
                    "mode": .string(offer.mode.rawValue), "duration": .string(offer.duration.rawValue),
                    "number_of_periods": number(offer.numberOfPeriods), "prices": .array(prices)]
        }
        return ["kind": "subscription", "asc_id": .string(subscription.ascId), "product_id": .string(subscription.productId),
                "name": .string(subscription.name), "period": .string(subscription.period.rawValue),
                "catalog_read_at": timestamp(snapshot.takenAt), "prices": .array(rows), "promotional_offers": .array(offers)]
    }

    private static func introOffer(_ offer: IntroOfferRow) -> JSONValue {
        ["mode": .string(offer.mode.rawValue), "duration": .string(offer.duration.rawValue), "number_of_periods": number(offer.numberOfPeriods),
         "price": optional(offer.customerPrice), "start_date": optional(offer.startDate), "end_date": optional(offer.endDate)]
    }

    private static func iapPrices(_ iap: IAPInfo, snapshot: CatalogSnapshot, territories: Set<TerritoryCode>?) -> JSONValue {
        let schedule = snapshot.iapSchedules[iap.ascId]
        let manual = (schedule?.manualPrices ?? []).filter { territories?.contains($0.territory) ?? true }.map { price -> JSONValue in
            ["territory": .string(price.territory.rawValue), "currency": optional(snapshot.territories[price.territory]?.rawValue),
             "price": number(price.customerPrice), "start_date": optional(price.startDate), "end_date": optional(price.endDate)]
        }
        return ["kind": "in_app_purchase", "asc_id": .string(iap.ascId), "product_id": .string(iap.productId), "name": .string(iap.name),
                "catalog_read_at": timestamp(snapshot.takenAt), "base_territory": optional(schedule?.baseTerritory.rawValue),
                "manual_prices": .array(manual),
                "note": "Apple equalizes every territory without a manual price from the base territory; those prices are not listed here."]
    }

    // MARK: Import

    public static func targetKind(_ kind: TargetKind) -> String {
        switch kind {
        case let .regularPrice(planType): return "regular price (\(planType.rawValue))"
        case let .introPayUpFront(duration): return "intro offer PAY_UP_FRONT \(duration.rawValue)"
        case let .introPayAsYouGo(duration, periods): return "intro offer PAY_AS_YOU_GO \(periods) x \(duration.rawValue)"
        case .introFreeTrial: return "intro free trial: a duration (ONE_WEEK) or a number of days (3, 7, 14, 30, 60, 90, 180, 365)"
        case let .promoPrice(offerCode): return "promotional offer price (\(offerCode))"
        case .iapManualPrice: return "in-app purchase manual price"
        }
    }

    public static func importMapping(_ mapping: ImportMapping, productName: (String) -> String) -> JSONValue {
        let columns = mapping.targets.map { target -> JSONValue in
            var column: [String: JSONValue] = ["column": .string(target.column.uppercased()), "product": .string(productName(target.productAscId)),
                                               "product_asc_id": .string(target.productAscId), "holds": .string(targetKind(target.kind)),
                                               "written": .bool(target.writes)]
            if let discount = target.nominalDiscount { column["nominal_discount_percent"] = number(discount * 100) }
            return .object(column)
        }
        return ["mapping_version": number(mapping.version), "first_data_row": number(mapping.firstDataRow),
                "country_column": .string(mapping.countryColumn.uppercased()), "currency_column": .string(mapping.currencyColumn.uppercased()),
                "columns": .array(columns),
                "notes": ["One row per territory. The country column holds the App Store storefront name exactly as export_import_template writes it; the currency column holds the territory's ISO 4217 code.",
                          "Amounts are plain numbers with a decimal point, no currency sign and no thousands separator.",
                          "A column with written = false is only compared with the live price; create_import_plan lists the differences as check_differences.",
                          "An empty cell carries no value: a regular, intro or promotional price stays as it is. An in-app purchase column replaces the whole schedule, so a territory without a value loses its manual price."]]
    }

    /// Check-only cells whose snapped value differs from the live price.
    public static func checkDiffs(_ diffs: [CheckDiff], limit: Int = 100) -> JSONValue {
        .array(diffs.prefix(limit).map { diff in
            ["column": .string(diff.column), "cell": .string(diff.cell.storageKey), "imported": number(diff.imported),
             "snapped": optional(diff.snapped), "live": optional(diff.live)]
        })
    }

    // MARK: Findings

    public static func findings(_ groups: [FindingGroup], productName: (String) -> String) -> JSONValue {
        .array(groups.map { group in
            let sample = group.findings.prefix(5).map { finding -> JSONValue in
                ["cell": .string(finding.cell.storageKey), "message": .string(finding.message)]
            }
            return ["group_id": .string(group.id), "type": .string(group.type.rawValue), "rule": optional(group.rule?.rawValue),
                    "product": .string(productName(group.productAscId)), "product_asc_id": .string(group.productAscId),
                    "cells": number(group.cellCount), "territories": .array(group.territories.sorted().map { .string($0.rawValue) }),
                    "examples": .array(Array(sample))]
        })
    }

    // MARK: Plans

    public static func planSummary(_ plan: StoredPlan) -> JSONValue {
        ["plan_id": .string(plan.id), "origin": .string(plan.origin.rawValue), "state": .string(plan.state.rawValue),
         "pause_reason": optional(plan.pauseReason?.rawValue), "end_reason": optional(plan.endReason?.rawValue),
         "reason": optional(plan.reason), "replan_of": optional(plan.replanOf),
         "estimate_requests": number(plan.estimateRequests), "estimate_minutes": number(plan.estimateMinutes),
         "created_at": timestamp(plan.createdAt), "updated_at": timestamp(plan.updatedAt)]
    }

    public static func severity(_ severity: Severity) -> String {
        switch severity {
        case .block(.plan): return "BLOCK"
        case .block(.cell): return "BLOCK_CELL"
        case let .confirm(level): return "CONFIRM_C\(level.rawValue)"
        case .warn: return "WARN"
        case .pause: return "PAUSE"
        }
    }

    public static func verdict(_ verdict: Verdict) -> JSONValue {
        ["rule": .string(verdict.rule.rawValue), "severity": .string(severity(verdict.severity)),
         "cell": optional(verdict.cell?.storageKey), "message": .string(verdict.message), "risk_class": optional(verdict.riskClass)]
    }

    /// The C2 risk classes of a set of verdicts, as the Executor counts them for the confirmation.
    public static func riskClasses(_ verdicts: [Verdict]) -> [String] {
        Set(verdicts.filter { $0.severity == .confirm(.c2) }.compactMap(\.riskClass)).sorted()
    }

    /// What apply_plan must carry for this plan. The preflight can still raise the level; apply_plan then says so.
    public static func confirmationNeeded(level: ConfirmationLevel, excluded: Int, verdicts: [Verdict], appName: String) -> JSONValue {
        var needed: [String: JSONValue] = ["level": .string("C\(level.rawValue)")]
        if excluded > 0 { needed["acknowledge_exclusions"] = true }
        if level >= .c1 { needed["typed_app_name"] = .string(appName) }
        if level >= .c2 {
            needed["reason"] = .string("at least \(AppleConstants.c2MinReasonLength) characters")
            needed["checked_risk_classes"] = .array(riskClasses(verdicts).map(JSONValue.string))
        }
        return .object(needed)
    }

    public static func plan(_ plan: StoredPlan, items: [StoredItem], rows: [PlanDiffRow], appName: String,
                            productName: (String) -> String, flaggedOnly: Bool, maxRows: Int) -> JSONValue {
        let states = Dictionary(items.map { ($0.item.seq, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = rows.filter { !flaggedOnly || $0.isMarked }
        let rendered = shown.prefix(max(0, maxRows)).map { row -> JSONValue in
            var entry: [String: JSONValue] = [
                "seq": number(row.seq), "op": .string(row.op.rawValue), "product": .string(productName(row.cell.productAscId)),
                "cell": .string(row.cell.storageKey), "territory": optional(row.territory?.rawValue), "currency": optional(row.currency?.rawValue),
                "before": .string(row.before), "after": .string(row.after), "date": optional(row.date),
                "state": optional(states[row.seq]?.state.rawValue),
            ]
            if let delta = row.deltaPercent { entry["delta_percent"] = number(delta) }
            if let imported = row.importedValue { entry["imported"] = number(imported) }
            if !row.flags.isEmpty { entry["flags"] = .array(row.flags.map { .string($0.rawValue) }) }
            if !row.verdicts.isEmpty { entry["verdicts"] = .array(row.verdicts.map(verdict)) }
            if let error = states[row.seq]?.errorJSON { entry["error"] = .string(error) }
            return .object(entry)
        }
        let itemStates = Dictionary(grouping: items, by: \.state.rawValue).mapValues { number($0.count) }
        var result: [String: JSONValue] = [:]
        if case let .object(summary) = planSummary(plan) { result = summary }
        result["blocked"] = .bool(plan.verdicts.contains { if case .block = $0.severity { return true } else { return false } })
        // Verdicts on cells are repeated on their rows; the plan-level list keeps the ones without a cell and one per rule.
        var seenRules: Set<String> = []
        result["verdicts"] = .array(plan.verdicts.filter { $0.cell == nil || seenRules.insert($0.rule.rawValue + severity($0.severity)).inserted }.map(verdict))
        result["excluded_cells"] = number(plan.excluded.count)
        result["confirmation_needed"] = confirmationNeeded(level: plan.confirmationLevel, excluded: plan.excluded.count,
                                                           verdicts: plan.verdicts, appName: appName)
        result["item_states"] = .object(itemStates)
        result["rows_total"] = number(rows.count)
        result["rows_matching"] = number(shown.count)
        result["rows"] = .array(Array(rendered))
        return .object(result)
    }
}
