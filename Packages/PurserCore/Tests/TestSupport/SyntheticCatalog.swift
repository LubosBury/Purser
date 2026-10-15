import Foundation
import Domain
import Catalog

/// Builds synthetic CatalogSnapshots (invented products and prices only).
public struct SyntheticCatalog {
    public static let today = CalendarDate(year: 2026, month: 10, day: 9)
    public static let longAgo = CalendarDate(year: 2025, month: 1, day: 1)
    /// Ladder 0.99, 1.99, ... 99.99 used for every synthetic product and territory.
    public static let ladder: [Decimal] = (0..<100).map { Decimal($0) + Decimal(string: "0.99")! }

    public var syncId: Int64 = 7
    public var subscriptions: [String: SubscriptionInfo] = [:]
    public var iaps: [String: IAPInfo] = [:]
    public var territories: [TerritoryCode: CurrencyCode] = [:]
    public var regularRows: [RegularPriceRow] = []
    public var introRows: [IntroOfferRow] = []
    public var promoOffers: [PromoOffer] = []
    public var iapSchedules: [String: IAPSchedule] = [:]
    public var pricePoints: [PricePoint] = []
    public var offerCodes: Set<String> = []
    public var groups: [String: SubscriptionGroupInfo] = [:]
    public var metadata: [LocalizationOwner: OwnerMetadata] = [:]

    public init() {}

    public static func d(_ text: String) -> Decimal { Decimal(string: text)! }

    public static func pointId(_ product: String, _ territory: TerritoryCode, _ planType: PlanType?, _ price: Decimal) -> String {
        "pp|\(product)|\(territory)|\(planType?.rawValue ?? "-")|\(price)"
    }

    public static func config(isProduction: Bool = false, mapping: ImportMapping? = nil) -> WorkspaceConfig {
        WorkspaceConfig(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Synthetic", colorHex: "#3366FF",
                        isProduction: isProduction, appId: "app-1", bundleId: "com.example.synthetic", keyKind: .team,
                        keyId: "KEY123", issuerId: "issuer-1", importMapping: mapping, googleClientId: nil,
                        slackWebhookEnabled: false, nightlySyncHourUTC: 3)
    }

    /// Adds a subscription with a current regular price per territory and the synthetic ladder per territory.
    public mutating func addSubscription(_ ascId: String, prices: [TerritoryCode: Decimal], period: SubscriptionPeriod = .oneYear,
                                         state: ProductState = .approved, monthly: Bool = false,
                                         available: Set<TerritoryCode>? = nil, currency: CurrencyCode = "USD") {
        let territorySet = Set(prices.keys).union(available ?? [])
        subscriptions[ascId] = SubscriptionInfo(ascId: ascId, productId: "com.example.\(ascId)", name: "Synthetic \(ascId)",
                                                period: period, state: state, groupId: "group-1", groupName: "Synthetic group",
                                                availableTerritories: available ?? Set(prices.keys), monthlyPlanAvailable: monthly)
        for t in territorySet where territories[t] == nil { territories[t] = currency }
        addLadder(product: ascId, territories: territorySet, planType: .upfront)
        if monthly { addLadder(product: ascId, territories: territorySet, planType: .monthly) }
        for (t, price) in prices { setRegular(ascId, t, price) }
    }

    public mutating func addLadder(product: String, territories: some Sequence<TerritoryCode>, planType: PlanType?,
                                   prices: [Decimal] = SyntheticCatalog.ladder) {
        for t in territories {
            for price in prices {
                pricePoints.append(PricePoint(id: Self.pointId(product, t, planType, price), productAscId: product, territory: t,
                                              planType: planType, customerPrice: price, proceeds: price * Decimal(string: "0.7")!))
            }
        }
    }

    public mutating func setRegular(_ sub: String, _ t: TerritoryCode, _ price: Decimal, start: CalendarDate? = SyntheticCatalog.longAgo,
                                    planType: PlanType = .upfront, ascId: String? = nil) {
        regularRows.append(RegularPriceRow(ascId: ascId ?? "rp-\(sub)-\(t)-\(planType.rawValue)-\(start?.iso ?? "nil")", subscriptionId: sub,
                                           territory: t, planType: planType, rawPlanType: planType.rawValue, startDate: start,
                                           preserved: false, pricePointId: Self.pointId(sub, t, planType, price), customerPrice: price))
    }

    public mutating func addIntro(_ sub: String, _ t: TerritoryCode, mode: OfferMode = .payUpFront, duration: OfferDuration = .oneYear,
                                  periods: Int = 1, price: Decimal?, start: CalendarDate? = CalendarDate(year: 2026, month: 1, day: 1),
                                  end: CalendarDate? = nil, ascId: String? = nil) {
        introRows.append(IntroOfferRow(ascId: ascId ?? "io-\(sub)-\(t)-\(start?.iso ?? "nil")", subscriptionId: sub, territory: t,
                                       planType: .upfront, rawPlanType: "UPFRONT", mode: mode, duration: duration,
                                       numberOfPeriods: periods, startDate: start, endDate: end,
                                       pricePointId: price.map { Self.pointId(sub, t, .upfront, $0) }, customerPrice: price))
    }

    public mutating func addPromo(_ sub: String, code: String, mode: OfferMode = .payAsYouGo, duration: OfferDuration = .oneYear,
                                  periods: Int = 1, prices: [TerritoryCode: Decimal?], ascId: String? = nil) {
        offerCodes.insert(code)
        promoOffers.append(PromoOffer(ascId: ascId ?? "po-\(code)", subscriptionId: sub, offerCode: code, name: "Promo \(code)",
                                      mode: mode, duration: duration, numberOfPeriods: periods, planType: .upfront,
                                      prices: prices.map { t, price in
                                          PromoPrice(ascId: "pp-\(code)-\(t)", territory: t,
                                                     pricePointId: price.map { Self.pointId(sub, t, .upfront, $0) }, customerPrice: price)
                                      }))
    }

    public mutating func addIAP(_ ascId: String, base: TerritoryCode, manual: [TerritoryCode: Decimal], state: ProductState = .approved) {
        iaps[ascId] = IAPInfo(ascId: ascId, productId: "com.example.\(ascId)", name: "Synthetic \(ascId)", iapType: "NON_CONSUMABLE", state: state)
        addLadder(product: ascId, territories: manual.keys, planType: nil)
        iapSchedules[ascId] = IAPSchedule(iapId: ascId, scheduleId: "sched-\(ascId)", baseTerritory: base,
                                          manualPrices: manual.map { t, price in
                                              IAPManualPrice(ascId: "mp-\(ascId)-\(t)", territory: t,
                                                             pricePointId: Self.pointId(ascId, t, nil, price),
                                                             startDate: nil, endDate: nil, customerPrice: price)
                                          })
        for t in manual.keys where territories[t] == nil { territories[t] = "USD" }
    }

    /// A subscription group; addSubscription puts every subscription into "group-1".
    public mutating func addGroup(_ ascId: String = "group-1", name: String = "Synthetic group") {
        groups[ascId] = SubscriptionGroupInfo(ascId: ascId, referenceName: name)
    }

    /// The owner's versions and texts: a live version with `live` (none when empty), then, with `pendingState`, a newer
    /// version with `pending`. Ids: "ver-<owner id>-<number>" and "loc-<owner id>-<number>-<locale>".
    public mutating func addTexts(_ owner: LocalizationOwner, live: [String: LocalizationText], pending: [String: LocalizationText] = [:],
                                  pendingState: MetadataVersionState? = nil) {
        var versions: [MetadataVersion] = []
        var rows: [LocalizationRow] = []
        func add(_ state: MetadataVersionState, _ texts: [String: LocalizationText]) {
            let number = versions.count + 1
            let id = "ver-\(owner.ascId)-\(number)"
            versions.append(MetadataVersion(ascId: id, owner: owner, number: number, state: state))
            rows += texts.map { LocalizationRow(ascId: "loc-\(owner.ascId)-\(number)-\($0.key)", owner: owner, versionId: id, locale: $0.key, text: $0.value) }
        }
        if !live.isEmpty { add(.approved, live) }
        if let pendingState { add(pendingState, pending) }
        metadata[owner] = OwnerMetadata(owner: owner, versions: versions, localizations: rows)
    }

    public func snapshot() -> CatalogSnapshot {
        CatalogSnapshot(syncId: syncId, takenAt: SyntheticCatalog.today.startOfDayUTC, subscriptions: subscriptions, iaps: iaps,
                        territories: territories, regularRows: regularRows, introRows: introRows, promoOffers: promoOffers,
                        iapSchedules: iapSchedules, pricePoints: PricePointIndex(pricePoints), offerCodesEverSeen: offerCodes,
                        groups: groups, metadata: metadata)
    }
}
