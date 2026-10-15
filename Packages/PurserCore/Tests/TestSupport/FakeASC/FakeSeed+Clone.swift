import Foundation
import Domain

extension FakeSeed {
    /// The Purser Spike seed with everything a clone copies. SpikeYearlyA (sub-spike-a): level 1, Family Sharing, a review
    /// note, availability everywhere and in new territories, texts cs and en-US in version 1, a committed review screenshot,
    /// a current free trial of one week everywhere and the PAY_AS_YOU_GO promo "spike_winback" at point 4.
    /// PurserSpikeLifetime (iap-spike): a review note, availability everywhere, an en-US text and a screenshot. The group
    /// "Purser Spike": an en-US text with a custom app name. All synthetic.
    public static func cloneSource() -> FakeModel {
        var model = fruitJarWithSpikeGroup()
        let all = Set(model.territories.keys)
        if let index = model.subscriptions.firstIndex(where: { $0.id == "sub-spike-a" }) {
            model.subscriptions[index].familySharable = true
            model.subscriptions[index].reviewNote = "Synthetic review note for the yearly plan"
            model.subscriptions[index].groupLevel = 1
        }
        model.availabilityInNew["sub-spike-a"] = true
        if let index = model.iaps.firstIndex(where: { $0.id == "iap-spike" }) {
            model.iaps[index].reviewNote = "Synthetic review note for the lifetime purchase"
            model.iaps[index].availableTerritories = all
        }
        model.availabilityInNew["iap-spike"] = false
        // The Purser Spike seed already has a version 1 with an en-US text for each of these owners; the clone source replaces
        // them with its own ids and texts so that every owner keeps exactly one version 1.
        let spikeOwners: Set<LocalizationOwner> = [.group("grp-spike"), .subscription("sub-spike-a"), .iap("iap-spike")]
        let replacedVersions = Set(model.versions.filter { spikeOwners.contains($0.owner) }.map(\.id))
        model.versions.removeAll { replacedVersions.contains($0.id) }
        model.localizations.removeAll { replacedVersions.contains($0.versionId) }
        model.versions += [
            FakeVersion(id: "gver-spike-1", owner: .group("grp-spike"), number: 1, state: .prepareForSubmission),
            FakeVersion(id: "sver-spike-a-1", owner: .subscription("sub-spike-a"), number: 1, state: .prepareForSubmission),
            FakeVersion(id: "iver-spike-1", owner: .iap("iap-spike"), number: 1, state: .prepareForSubmission),
        ]
        model.localizations += [
            FakeLocalization(id: "gloc-spike-en", versionId: "gver-spike-1", locale: "en-US",
                             text: LocalizationText(name: "Purser Spike Pro", customAppName: "Spike")),
            FakeLocalization(id: "sloc-spike-a-cs", versionId: "sver-spike-a-1", locale: "cs",
                             text: LocalizationText(name: "Spike na rok", description: "Synteticky rocni plan")),
            FakeLocalization(id: "sloc-spike-a-en", versionId: "sver-spike-a-1", locale: "en-US",
                             text: LocalizationText(name: "Spike Yearly", description: "Synthetic yearly plan")),
            FakeLocalization(id: "iloc-spike-en", versionId: "iver-spike-1", locale: "en-US",
                             text: LocalizationText(name: "Spike Lifetime", description: "Synthetic lifetime purchase")),
        ]
        let screenshots: [(String, LocalizationOwner)] = [("shot-spike-a", .subscription("sub-spike-a")), ("shot-spike-life", .iap("iap-spike"))]
        for (id, owner) in screenshots {
            model.screenshots.append(FakeScreenshot(id: id, owner: owner, fileName: "\(id).png", fileSize: FakeASC.samplePNG.count,
                                                    state: "COMPLETE", received: FakeASC.samplePNG, receivedParts: [1],
                                                    checksum: FakeASC.md5(FakeASC.samplePNG), templateURL: FakeASC.imageTemplate(screenshotId: id),
                                                    width: 1, height: 1))
        }
        for territory in all.sorted() {
            model.intros.append(FakeIntro(id: "intro-spike-a-\(territory)", subscriptionId: "sub-spike-a", territory: territory,
                                          planType: .upfront, mode: .freeTrial, duration: .oneWeek, numberOfPeriods: 1,
                                          startDate: seedStart, endDate: nil, pricePointId: nil, createdOn: seedStart))
        }
        model.promos.append(FakePromo(id: "promo-spike-a", subscriptionId: "sub-spike-a", offerCode: "spike_winback", name: "Spike winback",
                                      mode: .payAsYouGo, duration: .oneYear, numberOfPeriods: 1, planType: .upfront,
                                      prices: all.sorted().map {
                                          FakePromoPrice(id: "promoprice-spike-a-\($0)", territory: $0, pricePointId: "pp-sub-spike-a-\($0)-4")
                                      }))
        model.usedOfferCodes.insert("spike_winback")
        return model
    }
}
