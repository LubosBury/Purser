import Testing
import Domain

@Suite struct CellKeyTests {
    @Test(arguments: [
        (CellKey.regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront), "R|6500000001|USA|UPFRONT"),
        (CellKey.intro(subscriptionId: "6500000001", territory: "CZE", planType: .monthly), "I|6500000001|CZE|MONTHLY"),
        (CellKey.promo(subscriptionId: "6500000002", offerCode: "SPRING_v1"), "P|6500000002|SPRING_v1"),
        (CellKey.iapSchedule(iapId: "6600000001"), "L|6600000001"),
        (CellKey.localization(owner: .subscription("6500000001"), locale: "en-US"), "T|S|6500000001|en-US"),
        (CellKey.localization(owner: .group("7000000001"), locale: "zh-Hans"), "T|G|7000000001|zh-Hans"),
        (CellKey.metadataVersion(owner: .iap("6600000001")), "V|I|6600000001"),
    ])
    func storageKeyRoundTrips(_ key: CellKey, _ expected: String) {
        #expect(key.storageKey == expected)
        #expect(key.description == expected)
        #expect(CellKey(storageKey: expected) == key)
    }

    @Test(arguments: ["", "R|1|USA", "R|1|USA|WEEKLY", "I|1|USA", "P|1", "L", "L|1|2", "X|1|USA|UPFRONT",
                      "T|S|1", "T|X|1|en-US", "T|S||en-US", "T|S|1|", "T|S|1|en-US|x", "V|S", "V|Q|1", "V|S|", "V|S|1|2"])
    func rejectsMalformedStorageKeys(_ text: String) {
        #expect(CellKey(storageKey: text) == nil)
    }

    @Test func exposesProductAndTerritory() {
        let regular = CellKey.regular(subscriptionId: "6500000001", territory: "usa", planType: .upfront)
        #expect(regular.productAscId == "6500000001")
        #expect(regular.territory == "USA")
        #expect(CellKey.promo(subscriptionId: "6500000002", offerCode: "A").territory == nil)
        #expect(CellKey.iapSchedule(iapId: "6600000001").productAscId == "6600000001")
    }

    @Test func textAndVersionCellsExposeTheirOwner() {
        let text = CellKey.localization(owner: .group("7000000001"), locale: "cs")
        #expect(text.productAscId == "7000000001")
        #expect(text.territory == nil)
        #expect(text.localizationOwner == .group("7000000001"))
        let version = CellKey.metadataVersion(owner: .subscription("6500000001"))
        #expect(version.productAscId == "6500000001")
        #expect(version.territory == nil)
        #expect(version.localizationOwner == .subscription("6500000001"))
        #expect(CellKey.iapSchedule(iapId: "6600000001").localizationOwner == nil)
        #expect(CellKey.regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront).localizationOwner == nil)
    }
}
