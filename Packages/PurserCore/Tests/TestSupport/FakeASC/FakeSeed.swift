import Foundation
import Domain

/// Synthetic catalogs. Nothing here describes a real app.
public enum FakeSeed {
    public static let appId = "1000000001"
    public static let seedStart = CalendarDate(year: 2026, month: 1, day: 1)

    /// FruitJar: sub-y (yearly, APPROVED), sub-m (monthly, READY_TO_SUBMIT), sub-n (yearly, MISSING_METADATA, no prices),
    /// iap-life (lifetime). Six territories, price points "pp-<product>-<territory>-<i>" priced 0.99 + i.
    /// Texts: sub-y has a live version 1 in en-US and cs, sub-n only version 1 in PREPARE_FOR_SUBMISSION (en-US),
    /// iap-life and the group grp-1 a live version 1 in en-US; sub-m has no version.
    public static func fruitJar() -> FakeModel {
        let territories: [TerritoryCode: CurrencyCode] = ["USA": "USD", "CZE": "CZK", "DEU": "EUR", "FRA": "EUR", "GBR": "GBP", "JPN": "JPY"]
        let all = Set(territories.keys)
        let subs = [
            FakeSubscription(id: "sub-y", productId: "com.example.fruitjar.yearly", name: "Yearly", period: .oneYear,
                             state: .approved, groupId: "grp-1", availableTerritories: all),
            FakeSubscription(id: "sub-m", productId: "com.example.fruitjar.monthly", name: "Monthly", period: .oneMonth,
                             state: .readyToSubmit, groupId: "grp-1", availableTerritories: all),
            FakeSubscription(id: "sub-n", productId: "com.example.fruitjar.yearly.new", name: "Yearly New", period: .oneYear,
                             state: .missingMetadata, groupId: "grp-1", availableTerritories: all),
        ]
        var points: [FakePricePoint] = []
        for sub in subs {
            for territory in all.sorted() {
                for i in 0..<40 { points.append(point(product: sub.id, territory: territory, index: i, planType: .upfront)) }
            }
        }
        for territory in all.sorted() {
            for i in 0..<60 { points.append(point(product: "iap-life", territory: territory, index: i, planType: nil)) }
        }
        var regular: [FakeRegularPrice] = []
        for (sub, index) in [("sub-y", 9), ("sub-m", 2)] {
            for territory in all.sorted() {
                regular.append(FakeRegularPrice(id: "price-\(sub)-\(territory)-0", subscriptionId: sub, territory: territory,
                                                planType: .upfront, sendsPlanType: true, startDate: seedStart, preserved: false,
                                                pricePointId: "pp-\(sub)-\(territory)-\(index)"))
            }
        }
        return FakeModel(
            app: FakeApp(id: appId, bundleId: "com.example.fruitjar", name: "FruitJar"),
            territories: territories,
            groups: [FakeGroup(id: "grp-1", name: "Premium")],
            subscriptions: subs, pricePoints: points, regularPrices: regular, intros: [], promos: [], usedOfferCodes: [],
            iaps: [FakeIAP(id: "iap-life", productId: "com.example.fruitjar.lifetime", name: "Lifetime",
                           type: "NON_CONSUMABLE", state: .approved)],
            iapSchedules: [FakeIAPSchedule(id: "sched-0", iapId: "iap-life", baseTerritory: "USA", manualPrices: [
                FakeIAPManualPrice(id: "iapprice-0", territory: "USA", pricePointId: "pp-iap-life-USA-29", startDate: nil, endDate: nil)])],
            versions: [
                FakeVersion(id: "ver-sub-y-1", owner: .subscription("sub-y"), number: 1, state: .approved),
                FakeVersion(id: "ver-sub-n-1", owner: .subscription("sub-n"), number: 1, state: .prepareForSubmission),
                FakeVersion(id: "ver-iap-life-1", owner: .iap("iap-life"), number: 1, state: .approved),
                FakeVersion(id: "ver-grp-1-1", owner: .group("grp-1"), number: 1, state: .approved),
            ],
            localizations: [
                FakeLocalization(id: "loc-sub-y-1-en-US", versionId: "ver-sub-y-1", locale: "en-US",
                                 text: LocalizationText(name: "Yearly", description: "Every fruit, all year")),
                FakeLocalization(id: "loc-sub-y-1-cs", versionId: "ver-sub-y-1", locale: "cs",
                                 text: LocalizationText(name: "Ročně", description: "Všechno ovoce na celý rok")),
                FakeLocalization(id: "loc-sub-n-1-en-US", versionId: "ver-sub-n-1", locale: "en-US",
                                 text: LocalizationText(name: "Yearly New", description: "Fresh fruit, all year")),
                FakeLocalization(id: "loc-iap-life-1-en-US", versionId: "ver-iap-life-1", locale: "en-US",
                                 text: LocalizationText(name: "Lifetime", description: "Every fruit, forever")),
                FakeLocalization(id: "loc-grp-1-1-en-US", versionId: "ver-grp-1-1", locale: "en-US",
                                 text: LocalizationText(name: "Premium", customAppName: "FruitJar")),
            ])
    }

    /// Wide catalog for volume tests: territories T001...T<n> (USD), subscriptions sub-w1...sub-w<k> (yearly,
    /// MISSING_METADATA, so no lead-time rules apply), each with a current price at point index 9 everywhere.
    public static func wide(subscriptionCount: Int, territoryCount: Int) -> FakeModel {
        let codes = (1...territoryCount).map { TerritoryCode(String(format: "T%03d", $0)) }
        var territories: [TerritoryCode: CurrencyCode] = [:]
        for code in codes { territories[code] = "USD" }
        let subs = (1...subscriptionCount).map {
            FakeSubscription(id: "sub-w\($0)", productId: "com.example.fruitjar.wide\($0)", name: "Wide \($0)", period: .oneYear,
                             state: .missingMetadata, groupId: "grp-1", availableTerritories: Set(codes))
        }
        var points: [FakePricePoint] = []
        var regular: [FakeRegularPrice] = []
        for sub in subs {
            for code in codes {
                for i in 0..<10 { points.append(point(product: sub.id, territory: code, index: i, planType: .upfront)) }
                regular.append(FakeRegularPrice(id: "price-\(sub.id)-\(code)-0", subscriptionId: sub.id, territory: code,
                                                planType: .upfront, sendsPlanType: true, startDate: seedStart, preserved: false,
                                                pricePointId: "pp-\(sub.id)-\(code)-9"))
            }
        }
        return FakeModel(app: FakeApp(id: appId, bundleId: "com.example.fruitjar", name: "FruitJar"),
                         territories: territories, groups: [FakeGroup(id: "grp-1", name: "Premium")],
                         subscriptions: subs, pricePoints: points, regularPrices: regular, intros: [], promos: [],
                         usedOfferCodes: [], iaps: [], iapSchedules: [])
    }

    public static func point(product: String, territory: TerritoryCode, index: Int, planType: PlanType?) -> FakePricePoint {
        let price = Decimal(string: "0.99")! + Decimal(index)
        return FakePricePoint(id: "pp-\(product)-\(territory)-\(index)", productId: product, territory: territory,
                              planType: planType, customerPrice: price, proceeds: price * Decimal(string: "0.7")!)
    }
}
