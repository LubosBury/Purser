import Foundation
import Domain

/// One intro offer as shown in the catalog table.
public struct IntroSummary: Hashable, Sendable {
    public var ascId: String
    public var mode: OfferMode
    public var duration: OfferDuration
    public var numberOfPeriods: Int
    public var customerPrice: Decimal?
    /// customerPrice / regular price effective on the offer's first remaining day; nil for free trials or without a regular price.
    public var shareOfRegular: Decimal?
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
}

/// One territory row of the Catalog screen (spec §8).
public struct CatalogTableRow: Hashable, Sendable, Identifiable {
    public var id: TerritoryCode { territory }
    public var territory: TerritoryCode
    public var currency: CurrencyCode?
    public var isAvailable: Bool
    public var currentPrice: Decimal?
    public var currentAscId: String?
    public var scheduledPrice: Decimal?
    public var scheduledStart: CalendarDate?
    public var scheduledPreserved: Bool?
    public var currentIntro: IntroSummary?
    public var futureIntro: IntroSummary?
    public var promoCount: Int
    public var provenance: Provenance?
    public var findingCount: Int
    public var flags: [String]
    /// The cells a click on the row opens in the history panel.
    public var cells: [CellKey]
}

public enum CatalogTable {
    public static func subscriptionRows(snapshot: CatalogSnapshot, subscriptionId: String, planType: PlanType, today: CalendarDate,
                                        observations: [ObservationRecord], findings: [FindingRecord]) -> [CatalogTableRow] {
        guard let subscription = snapshot.subscriptions[subscriptionId] else { return [] }
        let provenanceByAscId = Dictionary(observations.map { ($0.ascId, $0.provenance) }, uniquingKeysWith: { _, last in last })
        let promos = snapshot.promoOffers(subscriptionId: subscriptionId)
        return snapshot.territories.keys.sorted().map { territory in
            let regularCell = CellKey.regular(subscriptionId: subscriptionId, territory: territory, planType: planType)
            let introCell = CellKey.intro(subscriptionId: subscriptionId, territory: territory, planType: planType)
            let current = snapshot.currentRegular(subscriptionId: subscriptionId, territory: territory, planType: planType, on: today)
            let scheduled = snapshot.scheduledRegular(subscriptionId: subscriptionId, territory: territory, planType: planType, on: today)
            let available = subscription.availableTerritories.contains(territory)
            var flags: [String] = []
            if !available { flags.append("unavailable") }
            if available && current == nil { flags.append("no price") }
            return CatalogTableRow(
                territory: territory,
                currency: snapshot.territories[territory],
                isAvailable: available,
                currentPrice: current?.customerPrice,
                currentAscId: current?.ascId,
                scheduledPrice: scheduled?.customerPrice,
                scheduledStart: scheduled?.startDate,
                scheduledPreserved: scheduled?.preserved,
                currentIntro: snapshot.currentIntro(subscriptionId: subscriptionId, territory: territory, planType: planType, on: today)
                    .map { summary($0, snapshot: snapshot, today: today) },
                futureIntro: snapshot.futureIntro(subscriptionId: subscriptionId, territory: territory, planType: planType, on: today)
                    .map { summary($0, snapshot: snapshot, today: today) },
                promoCount: promos.filter { offer in offer.prices.contains { $0.territory == territory } }.count,
                provenance: current.flatMap { provenanceByAscId[$0.ascId] },
                findingCount: findings.filter { $0.cell == regularCell || $0.cell == introCell }.count,
                flags: flags,
                cells: [regularCell, introCell])
        }
    }

    public static func iapRows(snapshot: CatalogSnapshot, iapId: String, today: CalendarDate,
                               observations: [ObservationRecord], findings: [FindingRecord]) -> [CatalogTableRow] {
        let cell = CellKey.iapSchedule(iapId: iapId)
        let schedule = snapshot.iapSchedules[iapId]
        let provenance = observations.first { $0.cell == cell }?.provenance
        let findingCount = findings.filter { $0.cell == cell }.count
        return snapshot.territories.keys.sorted().map { territory in
            let prices = schedule?.manualPrices.filter { $0.territory == territory } ?? []
            let current = prices.last { ($0.startDate.map { $0 <= today } ?? true) && ($0.endDate.map { today < $0 } ?? true) }
            let future = prices.first { $0.startDate.map { $0 > today } ?? false }
            var flags: [String] = []
            if schedule?.baseTerritory == territory { flags.append("base") }
            if prices.isEmpty { flags.append("generated from base") }
            return CatalogTableRow(
                territory: territory, currency: snapshot.territories[territory], isAvailable: true,
                currentPrice: current?.customerPrice, currentAscId: current?.ascId,
                scheduledPrice: future?.customerPrice, scheduledStart: future?.startDate, scheduledPreserved: nil,
                currentIntro: nil, futureIntro: nil, promoCount: 0, provenance: provenance,
                findingCount: findingCount, flags: flags, cells: [cell])
        }
    }

    static func summary(_ offer: IntroOfferRow, snapshot: CatalogSnapshot, today: CalendarDate) -> IntroSummary {
        let firstDay = max(offer.startDate ?? today, today)
        let regular = snapshot.regularPrice(subscriptionId: offer.subscriptionId, territory: offer.territory, planType: offer.planType, on: firstDay)
        var share: Decimal?
        if let price = offer.customerPrice, let regular, regular > 0 { share = price / regular }
        return IntroSummary(ascId: offer.ascId, mode: offer.mode, duration: offer.duration, numberOfPeriods: offer.numberOfPeriods,
                            customerPrice: offer.customerPrice, shareOfRegular: share, startDate: offer.startDate, endDate: offer.endDate)
    }
}
