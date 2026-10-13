import Testing
import Domain

/// Natural keys are persisted (item.natural_key), so these strings are golden: a change here breaks old plans.
@Suite struct NaturalKeyTests {
    @Test func regularPriceKeys() {
        let create = WritePayload.createRegularPrice(NewRegularPrice(
            subscriptionId: "6500000001", territory: "USA", planType: .upfront, pricePointId: "pp-USA-3499",
            startDate: CalendarDate(iso: "2026-11-01"), preserveCurrentPrice: true))
        #expect(NaturalKey.of(create) == "R+|6500000001|USA|UPFRONT|2026-11-01|pp-USA-3499|true")
        let immediate = WritePayload.createRegularPrice(NewRegularPrice(
            subscriptionId: "6500000001", territory: "CZE", planType: .upfront, pricePointId: "pp-CZE-0799",
            startDate: nil, preserveCurrentPrice: false))
        #expect(NaturalKey.of(immediate) == "R+|6500000001|CZE|UPFRONT|-|pp-CZE-0799|false")
        #expect(NaturalKey.of(.deleteRegularPrice(ascId: "price-9")) == "R-|price-9")
    }

    @Test func introKeys() {
        let paid = WritePayload.createIntro(NewIntroOffer(
            subscriptionId: "6500000001", territory: "DEU", planType: .upfront, mode: .payUpFront, duration: .threeMonths,
            numberOfPeriods: 1, startDate: CalendarDate(iso: "2026-11-01"), endDate: nil, pricePointId: "pp-DEU-0999"))
        #expect(NaturalKey.of(paid) == "I+|6500000001|DEU|UPFRONT|PAY_UP_FRONT|THREE_MONTHS|pp-DEU-0999|2026-11-01")
        let trial = WritePayload.createIntro(NewIntroOffer(
            subscriptionId: "6500000001", territory: "USA", planType: .upfront, mode: .freeTrial, duration: .oneWeek,
            numberOfPeriods: 1, startDate: nil, endDate: nil, pricePointId: nil))
        #expect(NaturalKey.of(trial) == "I+|6500000001|USA|UPFRONT|FREE_TRIAL|ONE_WEEK|-|-")
        #expect(NaturalKey.of(.endIntro(ascId: "intro-7", endDate: CalendarDate(year: 2026, month: 12, day: 1))) == "I~|intro-7|2026-12-01")
        #expect(NaturalKey.of(.deleteIntro(ascId: "intro-7")) == "I-|intro-7")
    }

    @Test func promoKeys() {
        let create = WritePayload.createPromo(NewPromoOffer(
            subscriptionId: "6500000001", offerCode: "SPRING_v1", name: "Spring", mode: .payAsYouGo, duration: .threeMonths,
            numberOfPeriods: 3, planType: .upfront, prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-USA-0499")]))
        #expect(NaturalKey.of(create) == "P+|6500000001|SPRING_v1")
        #expect(NaturalKey.of(.deletePromo(ascId: "promo-3")) == "P-|promo-3")
        let reprice = WritePayload.replacePromoPrices(ascId: "promo-3", prices: [
            NewPromoPrice(territory: "USA", pricePointId: "pp-USA-0499"),
            NewPromoPrice(territory: "CZE", pricePointId: nil),
        ])
        #expect(NaturalKey.of(reprice) == "P~|promo-3|ec457b4063597b4427402efe7e0737611c4fa7c44dd199c2c2675e825daa2292")
        // Order of the price set does not matter.
        let reordered = WritePayload.replacePromoPrices(ascId: "promo-3", prices: [
            NewPromoPrice(territory: "CZE", pricePointId: nil),
            NewPromoPrice(territory: "USA", pricePointId: "pp-USA-0499"),
        ])
        #expect(NaturalKey.of(reordered) == NaturalKey.of(reprice))
    }

    @Test func iapScheduleKey() {
        let schedule = WritePayload.replaceIAPSchedule(NewIAPSchedule(iapId: "6600000001", baseTerritory: "USA", manualPrices: [
            NewIAPManualPrice(territory: "USA", pricePointId: "iap-USA-4999", startDate: nil, endDate: nil),
            NewIAPManualPrice(territory: "CZE", pricePointId: "iap-CZE-1290", startDate: CalendarDate(iso: "2026-11-01"), endDate: nil),
        ]))
        #expect(NaturalKey.of(schedule) == "L~|6600000001|a87f7a4a285d8f722f48df45f62b13858df9a62eb9fa3d7190e5a060a1e7d9bc")
    }

    @Test func plannedItemStoresItsNaturalKey() {
        let payload = WritePayload.deleteRegularPrice(ascId: "price-9")
        let item = PlannedItem(seq: 1, cell: .regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront),
                               payload: payload, before: .regular(current: nil, scheduled: nil),
                               target: .regular(current: nil, scheduled: nil))
        #expect(item.naturalKey == "R-|price-9")
        #expect(item.op == .delete)
    }
}
