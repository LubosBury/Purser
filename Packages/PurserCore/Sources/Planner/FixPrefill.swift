import Foundation
import Domain
import Catalog
import Policy

/// Pre-filled "repair plan" for an I4 / I5 finding group: an intro plan over the affected territories with the live
/// offer's mode, duration and periods. Pricing and start date are chosen by the user on the New plan sheet.
public struct FixPrefill: Hashable, Sendable {
    public var findingIds: [Int64]
    public var subscriptionId: String
    public var territories: Set<TerritoryCode>
    public var mode: OfferMode
    public var duration: OfferDuration
    public var numberOfPeriods: Int
    public var nominalDiscount: Decimal?

    public static func forGroup(_ group: FindingGroup, snapshot: CatalogSnapshot, config: WorkspaceConfig, today: CalendarDate) -> FixPrefill? {
        guard group.rule == "I4" || group.rule == "I5", snapshot.subscriptions[group.productAscId] != nil else { return nil }
        let rows = group.findings.compactMap { finding -> IntroOfferRow? in
            guard case let .intro(sub, territory, planType) = finding.cell else { return nil }
            return snapshot.currentIntro(subscriptionId: sub, territory: territory, planType: planType, on: today)
                ?? snapshot.futureIntro(subscriptionId: sub, territory: territory, planType: planType, on: today)
        }
        guard let model = rows.first else { return nil }
        return FixPrefill(findingIds: group.findingIds, subscriptionId: group.productAscId, territories: group.territories,
                          mode: model.mode, duration: model.duration, numberOfPeriods: model.numberOfPeriods,
                          nominalDiscount: NominalDiscounts.from(mapping: config.importMapping)[group.productAscId])
    }

    public func spec(pricing: IntroPricing, startDate: CalendarDate?, canary: Bool) -> PlanSpec {
        .fix(findingIds: findingIds, underlying: .intro(IntroPlanSpec(
            subscriptionIds: [subscriptionId], mode: mode, duration: duration, numberOfPeriods: numberOfPeriods, pricing: pricing,
            startDate: startDate, endDate: nil, nominalDiscount: nominalDiscount,
            filter: PlanFilter(productAscIds: [subscriptionId], territories: territories), canary: canary)))
    }
}
