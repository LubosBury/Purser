import Foundation
import Testing
import Domain
@testable import ASCClient

private func canonical(_ data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data)
    let out = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: out, as: UTF8.self)
}

private func canonical(_ string: String) throws -> String { try canonical(Data(string.utf8)) }

private func body(_ value: JSONBody) throws -> String { try canonical(value.data()) }

@Suite("WriteBodies")
struct WriteBodiesTests {
    @Test func regularPriceBodySendsPlanTypePreserveAndTerritory() throws {
        let request = NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront,
                                      pricePointId: "pp-sub-y-CZE-12", startDate: CalendarDate(iso: "2026-11-02"),
                                      preserveCurrentPrice: true)
        let golden = """
        {"data":{"type":"subscriptionPrices",
          "attributes":{"startDate":"2026-11-02","preserveCurrentPrice":true,"planType":"UPFRONT"},
          "relationships":{
            "subscription":{"data":{"type":"subscriptions","id":"sub-y"}},
            "subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"pp-sub-y-CZE-12"}},
            "territory":{"data":{"type":"territories","id":"CZE"}}}}}
        """
        #expect(try body(WriteBodies.createRegularPrice(request)) == canonical(golden))
    }

    @Test func regularPriceWithoutStartDateSendsExplicitNull() throws {
        let request = NewRegularPrice(subscriptionId: "sub-n", territory: "USA", planType: .upfront,
                                      pricePointId: "pp-sub-n-USA-4", startDate: nil, preserveCurrentPrice: false)
        let golden = """
        {"data":{"type":"subscriptionPrices",
          "attributes":{"startDate":null,"preserveCurrentPrice":false,"planType":"UPFRONT"},
          "relationships":{
            "subscription":{"data":{"type":"subscriptions","id":"sub-n"}},
            "subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"pp-sub-n-USA-4"}},
            "territory":{"data":{"type":"territories","id":"USA"}}}}}
        """
        #expect(try body(WriteBodies.createRegularPrice(request)) == canonical(golden))
    }

    @Test func paidIntroBodyHasTerritoryAndPricePoint() throws {
        let offer = NewIntroOffer(subscriptionId: "sub-y", territory: "DEU", planType: .upfront, mode: .payUpFront,
                                  duration: .threeMonths, numberOfPeriods: 1, startDate: CalendarDate(iso: "2026-11-05"),
                                  endDate: nil, pricePointId: "pp-sub-y-DEU-3")
        let golden = """
        {"data":{"type":"subscriptionIntroductoryOffers",
          "attributes":{"duration":"THREE_MONTHS","offerMode":"PAY_UP_FRONT","numberOfPeriods":1,
                        "startDate":"2026-11-05","endDate":null,"targetSubscriptionPlanType":"UPFRONT"},
          "relationships":{
            "subscription":{"data":{"type":"subscriptions","id":"sub-y"}},
            "territory":{"data":{"type":"territories","id":"DEU"}},
            "subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"pp-sub-y-DEU-3"}}}}}
        """
        #expect(try body(WriteBodies.createIntro(offer)) == canonical(golden))
    }

    @Test func freeTrialIntroBodyHasTerritoryAndNoPricePoint() throws {
        let offer = NewIntroOffer(subscriptionId: "sub-m", territory: "FRA", planType: .upfront, mode: .freeTrial,
                                  duration: .oneWeek, numberOfPeriods: 1, startDate: nil, endDate: nil, pricePointId: nil)
        let golden = """
        {"data":{"type":"subscriptionIntroductoryOffers",
          "attributes":{"duration":"ONE_WEEK","offerMode":"FREE_TRIAL","numberOfPeriods":1,
                        "startDate":null,"endDate":null,"targetSubscriptionPlanType":"UPFRONT"},
          "relationships":{
            "subscription":{"data":{"type":"subscriptions","id":"sub-m"}},
            "territory":{"data":{"type":"territories","id":"FRA"}}}}}
        """
        #expect(try body(WriteBodies.createIntro(offer)) == canonical(golden))
    }

    @Test func paidIntroWithoutPricePointCannotBeBuilt() {
        let offer = NewIntroOffer(subscriptionId: "sub-y", territory: "DEU", planType: .upfront, mode: .payAsYouGo,
                                  duration: .oneYear, numberOfPeriods: 1, startDate: nil, endDate: nil, pricePointId: nil)
        #expect(throws: WriteBodyError.missingPricePoint("DEU")) { try WriteBodies.createIntro(offer) }
    }

    @Test func freeTrialWithPricePointCannotBeBuilt() {
        let offer = NewIntroOffer(subscriptionId: "sub-y", territory: "DEU", planType: .upfront, mode: .freeTrial,
                                  duration: .oneWeek, numberOfPeriods: 1, startDate: nil, endDate: nil, pricePointId: "pp-x")
        #expect(throws: WriteBodyError.freeTrialWithPricePoint("DEU")) { try WriteBodies.createIntro(offer) }
    }

    @Test func endIntroPatchesOnlyEndDate() throws {
        let golden = """
        {"data":{"type":"subscriptionIntroductoryOffers","id":"intro-7","attributes":{"endDate":"2026-12-01"}}}
        """
        #expect(try body(WriteBodies.endIntro(ascId: "intro-7", endDate: CalendarDate(iso: "2026-12-01")!)) == canonical(golden))
    }

    @Test func promoCreateUsesLocalIdsAndTopLevelIncluded() throws {
        let offer = NewPromoOffer(subscriptionId: "sub-y", offerCode: "winback_v1", name: "Win back", mode: .payAsYouGo,
                                  duration: .oneYear, numberOfPeriods: 1, planType: .upfront,
                                  prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-sub-y-USA-2"),
                                           NewPromoPrice(territory: "CZE", pricePointId: "pp-sub-y-CZE-2")])
        let golden = """
        {"data":{"type":"subscriptionPromotionalOffers",
          "attributes":{"duration":"ONE_YEAR","name":"Win back","numberOfPeriods":1,"offerCode":"winback_v1",
                        "offerMode":"PAY_AS_YOU_GO","targetSubscriptionPlanType":"UPFRONT"},
          "relationships":{
            "subscription":{"data":{"type":"subscriptions","id":"sub-y"}},
            "prices":{"data":[{"type":"subscriptionPromotionalOfferPrices","id":"${price-1}"},
                              {"type":"subscriptionPromotionalOfferPrices","id":"${price-2}"}]}}},
         "included":[
          {"type":"subscriptionPromotionalOfferPrices","id":"${price-1}","relationships":{
            "territory":{"data":{"type":"territories","id":"CZE"}},
            "subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"pp-sub-y-CZE-2"}}}},
          {"type":"subscriptionPromotionalOfferPrices","id":"${price-2}","relationships":{
            "territory":{"data":{"type":"territories","id":"USA"}},
            "subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"pp-sub-y-USA-2"}}}}]}
        """
        #expect(try body(WriteBodies.createPromo(offer)) == canonical(golden))
    }

    @Test func promoFreeTrialRowsCarryOnlyTerritory() throws {
        let offer = NewPromoOffer(subscriptionId: "sub-y", offerCode: "trial_v1", name: "Trial", mode: .freeTrial,
                                  duration: .oneMonth, numberOfPeriods: 1, planType: .upfront,
                                  prices: [NewPromoPrice(territory: "GBR", pricePointId: nil)])
        let golden = """
        {"data":{"type":"subscriptionPromotionalOffers",
          "attributes":{"duration":"ONE_MONTH","name":"Trial","numberOfPeriods":1,"offerCode":"trial_v1",
                        "offerMode":"FREE_TRIAL","targetSubscriptionPlanType":"UPFRONT"},
          "relationships":{
            "subscription":{"data":{"type":"subscriptions","id":"sub-y"}},
            "prices":{"data":[{"type":"subscriptionPromotionalOfferPrices","id":"${price-1}"}]}}},
         "included":[{"type":"subscriptionPromotionalOfferPrices","id":"${price-1}","relationships":{
            "territory":{"data":{"type":"territories","id":"GBR"}}}}]}
        """
        #expect(try body(WriteBodies.createPromo(offer)) == canonical(golden))
    }

    @Test func promoPaidRowWithoutPricePointCannotBeBuilt() {
        let offer = NewPromoOffer(subscriptionId: "sub-y", offerCode: "x_v1", name: "X", mode: .payUpFront,
                                  duration: .oneMonth, numberOfPeriods: 1, planType: .upfront,
                                  prices: [NewPromoPrice(territory: "JPN", pricePointId: nil)])
        #expect(throws: WriteBodyError.missingPricePoint("JPN")) { try WriteBodies.createPromo(offer) }
    }

    @Test func promoReplacePricesSendsFullSetWithSameIncludedShape() throws {
        let golden = """
        {"data":{"type":"subscriptionPromotionalOffers","id":"promo-3",
          "relationships":{"prices":{"data":[{"type":"subscriptionPromotionalOfferPrices","id":"${price-1}"}]}}},
         "included":[{"type":"subscriptionPromotionalOfferPrices","id":"${price-1}","relationships":{
            "territory":{"data":{"type":"territories","id":"USA"}},
            "subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"pp-sub-y-USA-1"}}}}]}
        """
        let value = WriteBodies.replacePromoPrices(ascId: "promo-3",
                                                   prices: [NewPromoPrice(territory: "USA", pricePointId: "pp-sub-y-USA-1")])
        #expect(try body(value) == canonical(golden))
    }

    @Test func iapScheduleSendsBaseTerritoryAndAllManualPrices() throws {
        let schedule = NewIAPSchedule(iapId: "iap-life", baseTerritory: "USA", manualPrices: [
            NewIAPManualPrice(territory: "USA", pricePointId: "pp-iap-life-USA-29", startDate: nil, endDate: nil),
            NewIAPManualPrice(territory: "CZE", pricePointId: "pp-iap-life-CZE-29", startDate: CalendarDate(iso: "2026-11-10"), endDate: nil)])
        let golden = """
        {"data":{"type":"inAppPurchasePriceSchedules","relationships":{
            "inAppPurchase":{"data":{"type":"inAppPurchases","id":"iap-life"}},
            "baseTerritory":{"data":{"type":"territories","id":"USA"}},
            "manualPrices":{"data":[{"type":"inAppPurchasePrices","id":"${price-1}"},
                                    {"type":"inAppPurchasePrices","id":"${price-2}"}]}}},
         "included":[
          {"type":"inAppPurchasePrices","id":"${price-1}","attributes":{"startDate":"2026-11-10","endDate":null},
           "relationships":{"inAppPurchaseV2":{"data":{"type":"inAppPurchases","id":"iap-life"}},
                            "inAppPurchasePricePoint":{"data":{"type":"inAppPurchasePricePoints","id":"pp-iap-life-CZE-29"}}}},
          {"type":"inAppPurchasePrices","id":"${price-2}","attributes":{"startDate":null,"endDate":null},
           "relationships":{"inAppPurchaseV2":{"data":{"type":"inAppPurchases","id":"iap-life"}},
                            "inAppPurchasePricePoint":{"data":{"type":"inAppPurchasePricePoints","id":"pp-iap-life-USA-29"}}}}]}
        """
        #expect(try body(WriteBodies.replaceIAPSchedule(schedule)) == canonical(golden))
    }

    private func route(_ payload: WritePayload) -> String {
        let r = WritePaths.request(for: payload)
        return "\(r.method) \(r.path)"
    }

    @Test func pathsForEveryPayload() {
        let d = CalendarDate(iso: "2026-12-01")!
        #expect(route(.deleteRegularPrice(ascId: "p1")) == "DELETE /v1/subscriptionPrices/p1")
        #expect(route(.endIntro(ascId: "i1", endDate: d)) == "PATCH /v1/subscriptionIntroductoryOffers/i1")
        #expect(route(.deleteIntro(ascId: "i1")) == "DELETE /v1/subscriptionIntroductoryOffers/i1")
        #expect(route(.replacePromoPrices(ascId: "o1", prices: [])) == "PATCH /v1/subscriptionPromotionalOffers/o1")
        #expect(route(.deletePromo(ascId: "o1")) == "DELETE /v1/subscriptionPromotionalOffers/o1")
        #expect(route(.replaceIAPSchedule(NewIAPSchedule(iapId: "x", baseTerritory: "USA", manualPrices: [])))
                == "POST /v1/inAppPurchasePriceSchedules")
    }

    @Test func deleteHasNoBody() throws {
        #expect(try WriteBodies.body(for: .deleteIntro(ascId: "i1")) == nil)
    }
}
