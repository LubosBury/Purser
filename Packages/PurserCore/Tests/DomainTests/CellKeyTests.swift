import Testing
import Domain

@Suite struct CellKeyTests {
    @Test(arguments: [
        (CellKey.regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront), "R|6500000001|USA|UPFRONT"),
        (CellKey.intro(subscriptionId: "6500000001", territory: "CZE", planType: .monthly), "I|6500000001|CZE|MONTHLY"),
        (CellKey.promo(subscriptionId: "6500000002", offerCode: "SPRING_v1"), "P|6500000002|SPRING_v1"),
        (CellKey.iapSchedule(iapId: "6600000001"), "L|6600000001"),
    ])
    func storageKeyRoundTrips(_ key: CellKey, _ expected: String) {
        #expect(key.storageKey == expected)
        #expect(key.description == expected)
        #expect(CellKey(storageKey: expected) == key)
    }

    @Test(arguments: ["", "R|1|USA", "R|1|USA|WEEKLY", "I|1|USA", "P|1", "L", "L|1|2", "X|1|USA|UPFRONT"])
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
}
