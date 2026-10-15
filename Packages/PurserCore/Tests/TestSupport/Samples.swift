import Foundation
import Domain

/// Synthetic test data. Nothing here describes a real app, product or price list.
public enum Sample {
    public static let workspaceId = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    public static let appId = "6400000001"
    public static let bundleId = "com.example.fruitjournal"
    public static let fixedNow = Date(timeIntervalSince1970: 1_791_547_200)   // 2026-10-09T12:00:00Z

    public static func config(isProduction: Bool = false, keyKind: KeyKind = .team) -> WorkspaceConfig {
        WorkspaceConfig(id: workspaceId, name: "Fruit Journal", colorHex: "#2E7D32", isProduction: isProduction,
                        appId: appId, bundleId: bundleId, keyKind: keyKind, keyId: "ABCDEF1234",
                        issuerId: keyKind == .team ? "69a6de70-0000-47e3-e053-5b8c7c11a4d1" : nil,
                        importMapping: nil, googleClientId: nil, slackWebhookEnabled: false, nightlySyncHourUTC: 3)
    }

    public static func subscription(_ ascId: String = "6500000001", productId: String = "fruit.yearly", period: SubscriptionPeriod = .oneYear,
                                    territories: Set<TerritoryCode> = ["USA", "CZE", "DEU"], monthly: Bool = false,
                                    state: ProductState = .approved) -> SubscriptionInfo {
        SubscriptionInfo(ascId: ascId, productId: productId, name: "Fruit \(productId)", period: period, state: state,
                         groupId: "7000000001", groupName: "Fruit Premium", availableTerritories: territories,
                         monthlyPlanAvailable: monthly)
    }

    public static func iap(_ ascId: String = "6600000001") -> IAPInfo {
        IAPInfo(ascId: ascId, productId: "fruit.lifetime", name: "Fruit Lifetime", iapType: "NON_CONSUMABLE", state: .approved)
    }

    public static func regular(_ ascId: String, sub: String = "6500000001", territory: TerritoryCode = "USA", price: String,
                               start: String? = nil, preserved: Bool = false, planType: PlanType = .upfront) -> RegularPriceRow {
        RegularPriceRow(ascId: ascId, subscriptionId: sub, territory: territory, planType: planType, rawPlanType: planType.rawValue,
                        startDate: start.flatMap(CalendarDate.init(iso:)), preserved: preserved,
                        pricePointId: "pp-\(territory)-\(price)", customerPrice: Decimal(string: price)!)
    }

    public static func intro(_ ascId: String, sub: String = "6500000001", territory: TerritoryCode = "USA",
                             mode: OfferMode = .freeTrial, duration: OfferDuration = .oneWeek, price: String? = nil,
                             start: String? = nil, end: String? = nil) -> IntroOfferRow {
        IntroOfferRow(ascId: ascId, subscriptionId: sub, territory: territory, planType: .upfront, rawPlanType: nil,
                      mode: mode, duration: duration, numberOfPeriods: 1,
                      startDate: start.flatMap(CalendarDate.init(iso:)), endDate: end.flatMap(CalendarDate.init(iso:)),
                      pricePointId: price.map { "pp-\(territory)-\($0)" }, customerPrice: price.flatMap { Decimal(string: $0) })
    }

    public static func promo(_ ascId: String, sub: String = "6500000001", code: String, prices: [(TerritoryCode, String?)]) -> PromoOffer {
        PromoOffer(ascId: ascId, subscriptionId: sub, offerCode: code, name: "Promo \(code)", mode: .payUpFront,
                   duration: .threeMonths, numberOfPeriods: 1, planType: .upfront,
                   prices: prices.map { territory, price in
                       PromoPrice(ascId: "\(ascId)-\(territory)", territory: territory,
                                  pricePointId: price.map { "pp-\(territory)-\($0)" }, customerPrice: price.flatMap { Decimal(string: $0) })
                   })
    }

    public static func version(_ ascId: String, owner: LocalizationOwner = .subscription("6500000001"), number: Int,
                               state: MetadataVersionState) -> MetadataVersion {
        MetadataVersion(ascId: ascId, owner: owner, number: number, state: state)
    }

    public static func text(_ ascId: String, owner: LocalizationOwner = .subscription("6500000001"), version: String, locale: String = "en-US",
                            name: String, description: String? = nil, customAppName: String? = nil) -> LocalizationRow {
        LocalizationRow(ascId: ascId, owner: owner, versionId: version, locale: locale,
                        text: LocalizationText(name: name, description: description, customAppName: customAppName))
    }

    public static func schedule(iapId: String = "6600000001", base: TerritoryCode = "USA", prices: [(TerritoryCode, String)]) -> IAPSchedule {
        IAPSchedule(iapId: iapId, scheduleId: iapId, baseTerritory: base,
                    manualPrices: prices.map { territory, price in
                        IAPManualPrice(ascId: "iap-price-\(territory)", territory: territory, pricePointId: "iap-\(territory)-\(price)",
                                       startDate: nil, endDate: nil, customerPrice: Decimal(string: price)!)
                    })
    }

    public static func pricePoint(_ productAscId: String = "6500000001", territory: TerritoryCode, price: String,
                                  planType: PlanType? = .upfront) -> PricePoint {
        PricePoint(id: "pp-\(territory)-\(price)", productAscId: productAscId, territory: territory, planType: planType,
                   customerPrice: Decimal(string: price)!, proceeds: nil)
    }
}
