import Foundation
import Testing
import Domain

@Suite struct CodableTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(T.self, from: encoder.encode(value))
    }

    @Test func territoryCodeEncodesAsPlainUppercaseString() throws {
        let data = try JSONEncoder().encode(["cze" as TerritoryCode, "USA"])
        #expect(String(decoding: data, as: UTF8.self) == "[\"CZE\",\"USA\"]")
        let back = try JSONDecoder().decode([TerritoryCode].self, from: Data("[\"deu\"]".utf8))
        #expect(back == [TerritoryCode("DEU")])
        #expect(back[0].rawValue == "DEU")
    }

    @Test func currencyAndRuleIdsEncodeAsPlainStrings() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Pair(currency: "czk", rule: "I4"))
        #expect(String(decoding: data, as: UTF8.self) == "{\"currency\":\"CZK\",\"rule\":\"I4\"}")
    }

    @Test func cellKeyRoundTripsThroughJSON() throws {
        let keys: [CellKey] = [
            .regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront),
            .intro(subscriptionId: "6500000001", territory: "CZE", planType: .monthly),
            .promo(subscriptionId: "6500000002", offerCode: "WINBACK_v1"),
            .iapSchedule(iapId: "6600000001"),
            .localization(owner: .subscription("6500000001"), locale: "en-US"),
            .metadataVersion(owner: .group("7000000001")),
        ]
        #expect(try roundTrip(keys) == keys)
    }

    @Test func localizationCellStateRoundTrips() throws {
        let version = MetadataVersion(ascId: "ver-2", owner: .subscription("6500000001"), number: 2, state: .prepareForSubmission)
        let live = LocalizationRow(ascId: "loc-1", owner: .subscription("6500000001"), versionId: "ver-1", locale: "cs",
                                   text: LocalizationText(name: "Ročně", description: "Celý rok ovoce"))
        var pending = live
        pending.ascId = "loc-2"
        pending.versionId = "ver-2"
        pending.text.name = "Roční"
        let states: [CellState] = [.localization(live: live, pending: pending, pendingVersion: version),
                                   .localization(live: nil, pending: nil, pendingVersion: nil),
                                   .metadataVersion(version), .metadataVersion(nil)]
        #expect(try roundTrip(states) == states)
    }

    @Test func cellStateWithDecimalPricesRoundTrips() throws {
        let row = RegularPriceRow(ascId: "price-1", subscriptionId: "6500000001", territory: "USA", planType: .upfront,
                                  rawPlanType: nil, startDate: CalendarDate(iso: "2026-11-01"), preserved: false,
                                  pricePointId: "pp-USA-2999", customerPrice: Decimal(string: "29.99")!)
        let state = CellState.regular(current: row, scheduled: nil)
        let back = try roundTrip(state)
        #expect(back == state)
        guard case let .regular(current?, nil) = back else {
            Issue.record("unexpected shape \(back)")
            return
        }
        #expect(current.customerPrice == Decimal(string: "29.99")!)
        #expect(current.customerPrice.description == "29.99")
    }

    @Test func writePayloadRoundTrips() throws {
        let payload = WritePayload.createIntro(NewIntroOffer(
            subscriptionId: "6500000001", territory: "DEU", planType: .upfront, mode: .payUpFront, duration: .threeMonths,
            numberOfPeriods: 1, startDate: CalendarDate(iso: "2026-11-01"), endDate: nil, pricePointId: "pp-DEU-0999"))
        #expect(try roundTrip(payload) == payload)
    }
}

private struct Pair: Codable, Equatable {
    var currency: CurrencyCode
    var rule: RuleID
}
