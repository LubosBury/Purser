import Foundation
import Domain

extension FakeSeed {
    /// FruitJar plus a synthetic never-submitted "Purser Spike" group: sub-spike-a (product id "SpikeYearlyA", 40 points per
    /// territory, current price at point 9 everywhere) and the IAP iap-spike (product id "PurserSpikeLifetime") with a USA schedule.
    public static func fruitJarWithSpikeGroup() -> FakeModel {
        var model = fruitJar()
        let all = Set(model.territories.keys)
        model.groups.append(FakeGroup(id: "grp-spike", name: "Purser Spike"))
        model.subscriptions.append(FakeSubscription(id: "sub-spike-a", productId: "SpikeYearlyA", name: "SpikeYearlyA", period: .oneYear,
                                                    state: .missingMetadata, groupId: "grp-spike", availableTerritories: all))
        for territory in all.sorted() {
            for i in 0..<40 { model.pricePoints.append(point(product: "sub-spike-a", territory: territory, index: i, planType: .upfront)) }
            for i in 0..<60 { model.pricePoints.append(point(product: "iap-spike", territory: territory, index: i, planType: nil)) }
            model.regularPrices.append(FakeRegularPrice(id: "price-sub-spike-a-\(territory)-0", subscriptionId: "sub-spike-a",
                                                        territory: territory, planType: .upfront, sendsPlanType: true,
                                                        startDate: seedStart, preserved: false,
                                                        pricePointId: "pp-sub-spike-a-\(territory)-9"))
        }
        model.iaps.append(FakeIAP(id: "iap-spike", productId: "PurserSpikeLifetime", name: "PurserSpikeLifetime",
                                  type: "NON_CONSUMABLE", state: .readyToSubmit))
        model.iapSchedules.append(FakeIAPSchedule(id: "sched-spike", iapId: "iap-spike", baseTerritory: "USA", manualPrices: [
            FakeIAPManualPrice(id: "iapprice-spike-0", territory: "USA", pricePointId: "pp-iap-spike-USA-29", startDate: nil, endDate: nil)]))
        let spikeTexts: [(owner: LocalizationOwner, name: String, second: String)] = [
            (.subscription("sub-spike-a"), "Spike Yearly A", "Spike yearly plan A"),
            (.group("grp-spike"), "Purser Spike", "Spike"),
            (.iap("iap-spike"), "Spike Lifetime", "Spike lifetime access"),
        ]
        for text in spikeTexts {
            let versionId = "ver-spike-\(text.owner.ascId)-1"
            model.versions.append(FakeVersion(id: versionId, owner: text.owner, number: 1, state: .prepareForSubmission))
            model.localizations.append(FakeLocalization(id: "loc-spike-\(text.owner.ascId)-en-US", versionId: versionId, locale: "en-US",
                                                        text: LocalizationText(name: text.name,
                                                                               description: text.owner.kind == .group ? nil : text.second,
                                                                               customAppName: text.owner.kind == .group ? text.second : nil)))
        }
        return model
    }
}
