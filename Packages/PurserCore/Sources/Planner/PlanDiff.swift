import Foundation
import Domain
import Catalog
import Importer

/// One row of the diff table on the Plan screen (= one item).
public struct PlanDiffRow: Hashable, Sendable, Identifiable {
    public var seq: Int
    public var op: ItemOp
    public var cell: CellKey
    public var territory: TerritoryCode?
    public var currency: CurrencyCode?
    public var before: String
    public var after: String
    public var beforePrice: Decimal?
    public var afterPrice: Decimal?
    public var deltaPercent: Decimal?
    public var importedValue: Decimal?
    public var effectiveDiscount: Decimal?
    public var percentOfRegular: Decimal?
    public var date: CalendarDate?
    public var flags: [ItemFlag]
    public var verdicts: [Verdict]
    /// Text cells (L10N): the locale and the effective texts before and after; nil for price cells.
    public var locale: String? = nil
    public var beforeText: LocalizationText? = nil
    public var afterText: LocalizationText? = nil

    public var id: Int { seq }
    /// Shown by the "flagged only" filter: rows with a flag or a verdict on their cell.
    public var isMarked: Bool { !flags.isEmpty || !verdicts.isEmpty }
}

public enum PlanDiff {
    public static func rows(items: [PlannedItem], verdicts: [Verdict], spec: PlanSpec, snapshot: CatalogSnapshot,
                            config: WorkspaceConfig, today: CalendarDate) -> [PlanDiffRow] {
        let imported = importedValues(spec: spec, config: config)
        let byCell = Dictionary(grouping: verdicts.filter { $0.cell != nil }) { $0.cell! }
        let plannedRegular = Dictionary(items.compactMap { item -> (String, RegularPriceRow)? in
            guard case let .regular(s, t, p) = item.cell, case let .regular(current, scheduled) = item.target,
                  let row = [scheduled, current].compactMap({ $0 }).first(where: { $0.ascId == PlannedRow.ascId }) else { return nil }
            return ("\(s)|\(t)|\(p.rawValue)", row)
        }, uniquingKeysWith: { _, last in last })

        return items.map { item in
            var row = PlanDiffRow(seq: item.seq, op: item.op, cell: item.cell, territory: item.cell.territory,
                                  currency: item.cell.territory.flatMap { snapshot.territories[$0] },
                                  before: describe(item.before), after: describe(item.target), beforePrice: nil, afterPrice: nil,
                                  deltaPercent: nil, importedValue: imported[item.cell], effectiveDiscount: nil, percentOfRegular: nil,
                                  date: nil, flags: item.flags, verdicts: byCell[item.cell] ?? [])
            switch item.payload {
            case let .createRegularPrice(price):
                row.beforePrice = item.beforeRegularCurrent?.customerPrice
                row.afterPrice = snapshot.pricePoints.point(id: price.pricePointId)?.customerPrice
                row.date = price.startDate
            case let .createIntro(offer):
                row.beforePrice = item.beforeIntroRow?.customerPrice
                row.afterPrice = offer.pricePointId.flatMap { snapshot.pricePoints.point(id: $0)?.customerPrice }
                row.date = offer.startDate
                let day = offer.startDate ?? today
                let key = "\(offer.subscriptionId)|\(offer.territory)|\(offer.planType.rawValue)"
                let regular: Decimal?
                if let planned = plannedRegular[key], (planned.startDate ?? today) <= day {
                    regular = planned.customerPrice
                } else {
                    regular = snapshot.regularPrice(subscriptionId: offer.subscriptionId, territory: offer.territory, planType: offer.planType, on: day)
                }
                if let after = row.afterPrice, let regular, regular > 0 {
                    row.percentOfRegular = after / regular
                    row.effectiveDiscount = 1 - after / regular
                }
            case let .endIntro(_, end):
                row.date = end
            case let .setLocalization(text):
                row.locale = text.locale
                row.beforeText = LocalizationSemantics.effectiveText(item.before)
                row.afterText = LocalizationSemantics.effectiveText(item.target)
                row.before = describe(locale: text.locale, row.beforeText)
                row.after = describe(locale: text.locale, row.afterText)
            default:
                break
            }
            if let before = row.beforePrice, let after = row.afterPrice, before > 0 { row.deltaPercent = (after - before) / before }
            return row
        }
    }

    /// Short human description of a cell state for the diff table.
    public static func describe(_ state: CellState) -> String {
        switch state {
        case let .regular(current, scheduled):
            var text = current.map { "\($0.customerPrice)" } ?? "—"
            if let scheduled { text += " → \(scheduled.customerPrice) from \(scheduled.startDate?.iso ?? "at once")" }
            return text
        case let .intro(current, future):
            let parts = [current, future].compactMap { $0 }.map(describe)
            return parts.isEmpty ? "—" : parts.joined(separator: " | ")
        case let .promo(offer):
            guard let offer else { return "—" }
            return "\(offer.offerCode) \(offer.mode.rawValue): \(offer.prices.count) prices"
        case let .iapSchedule(schedule):
            guard let schedule else { return "—" }
            return "base \(schedule.baseTerritory), \(schedule.manualPrices.count) manual prices"
        case let .localization(live, pending, version):
            var text = live.map(describe) ?? "—"
            if let pending {
                text += " → \(describe(pending))"
                if let version { text += " (version \(version.number), \(version.state))" }
            }
            return text
        case let .metadataVersion(version):
            guard let version else { return "—" }
            return "version \(version.number), \(version.state)"
        }
    }

    /// "en-US: Name — description" for an effective text; a group shows its custom app name; "—" without a text.
    static func describe(locale: String, _ text: LocalizationText?) -> String {
        guard let text else { return "—" }
        return "\(locale): \(text.name) — \(text.description ?? text.customAppName ?? "—")"
    }

    /// "<locale>: <name> — <description>"; a group shows its custom app name in the second slot.
    static func describe(_ row: LocalizationRow) -> String {
        describe(locale: row.locale, row.text)
    }

    static func describe(_ row: IntroOfferRow) -> String {
        let price = row.customerPrice.map { "\($0)" } ?? "free"
        let periods = row.mode == .payAsYouGo ? " ×\(row.numberOfPeriods)" : ""
        var text = "\(short(row.mode)) \(row.duration.rawValue)\(periods) \(price)"
        if let start = row.startDate { text += " from \(start)" }
        if let end = row.endDate { text += " until \(end)" }
        return text
    }

    static func short(_ mode: OfferMode) -> String {
        switch mode {
        case .freeTrial: return "TRIAL"
        case .payUpFront: return "PUF"
        case .payAsYouGo: return "PAYG"
        }
    }

    /// Imported amounts per cell of an import spec (write and check-only columns).
    static func importedValues(spec: PlanSpec, config: WorkspaceConfig) -> [CellKey: Decimal] {
        guard case let .importTable(importSpec) = spec.unwrapped, let mapping = config.importMapping else { return [:] }
        var result: [CellKey: Decimal] = [:]
        for target in mapping.targets {
            let column = target.column.uppercased()
            for row in importSpec.table.rows {
                guard let amount = row.values[column]?.amount else { continue }
                switch target.kind {
                case let .regularPrice(planType):
                    result[.regular(subscriptionId: target.productAscId, territory: row.territory, planType: planType)] = amount
                case .introPayUpFront, .introPayAsYouGo:
                    result[.intro(subscriptionId: target.productAscId, territory: row.territory, planType: .upfront)] = amount
                default:
                    continue
                }
            }
        }
        return result
    }
}

extension PlannedItem {
    var beforeRegularCurrent: RegularPriceRow? {
        if case let .regular(current, _) = before { return current } else { return nil }
    }

    var beforeIntroRow: IntroOfferRow? {
        if case let .intro(current, future) = before { return current ?? future } else { return nil }
    }
}

/// A field of a localized text, for the plan screen and MCP.
public enum LocalizationField: String, CaseIterable, Sendable {
    case name, description, customAppName

    public var label: String {
        switch self {
        case .name: return "Name"
        case .description: return "Description"
        case .customAppName: return "Custom app name"
        }
    }
}

extension PlanDiff {
    /// Fields whose text differs; with no text before, every field the after text sets. A nil after-field keeps the text.
    public static func changedFields(_ before: LocalizationText?, _ after: LocalizationText?) -> [LocalizationField] {
        guard let after else { return [] }
        var fields: [LocalizationField] = []
        if before?.name != after.name { fields.append(.name) }
        if after.description != nil, before?.description != after.description { fields.append(.description) }
        if after.customAppName != nil, before?.customAppName != after.customAppName { fields.append(.customAppName) }
        return fields
    }
}
