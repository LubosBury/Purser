import Foundation
import Testing
import Catalog
import Domain
import Planner
import PurserTestSupport

@Suite struct RegularPlanSpecCodingTests {
    @Test func oldJSONWithoutPromoRepricingDecodesToEmpty() throws {
        let spec = RegularPlanSpec(subscriptionIds: ["sub-1"], planType: .upfront,
                                   prices: [TerritoryAmount(territory: "USA", amount: Decimal(string: "39.99")!)],
                                   startDate: CalendarDate(year: 2030, month: 3, day: 10), preserveCurrentPrice: nil,
                                   skipIntroReplacement: [:], filter: PlanFilter())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let current = String(decoding: try encoder.encode(spec), as: UTF8.self)
        #expect(current.contains(#""promoRepricing":{},"#))
        // A spec stored before M4: the same JSON text without the key (no re-serialisation, so 39.99 stays exact).
        let old = current.replacingOccurrences(of: #""promoRepricing":{},"#, with: "")
        #expect(!old.contains("promoRepricing"))
        let decoded = try JSONDecoder().decode(RegularPlanSpec.self, from: Data(old.utf8))
        #expect(decoded.promoRepricing.isEmpty)
        #expect(decoded == spec)
    }

    @Test func promoRepricingRoundTrips() throws {
        let spec = RegularPlanSpec(subscriptionIds: ["sub-1"], planType: .upfront, prices: [],
                                   startDate: CalendarDate(year: 2030, month: 3, day: 10), preserveCurrentPrice: true,
                                   skipIntroReplacement: [.intro(subscriptionId: "sub-1", territory: "USA", planType: .upfront): "test reason"],
                                   filter: PlanFilter(territories: ["USA"]),
                                   promoRepricing: ["promo-1": .percentOfRegular(Decimal(string: "0.5")!)])
        let decoded = try JSONDecoder().decode(RegularPlanSpec.self, from: JSONEncoder().encode(spec))
        #expect(decoded == spec)
    }

    @Test func firstPriceOfAProductWithoutOneCanBeSentWithoutAStartDate() throws {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("fresh", prices: [:], state: .readyToSubmit, available: ["USA", "CZE"])
        let spec = PlanSpec.regular(RegularPlanSpec(subscriptionIds: ["fresh"], planType: .upfront,
                                                    prices: [TerritoryAmount(territory: "USA", amount: d("29.99"))],
                                                    startDate: nil, preserveCurrentPrice: nil, skipIntroReplacement: [:], filter: PlanFilter()))
        let draft = try plan(spec, catalog.snapshot())
        #expect(draft.blocks.isEmpty, "\(draft.verdicts)")
        guard case let .createRegularPrice(price) = draft.items.first?.payload else { Issue.record("no POST: \(draft.items)"); return }
        #expect(price.startDate == nil)
        #expect(!price.preserveCurrentPrice)
        let decoded = try JSONDecoder().decode(PlanSpec.self, from: JSONEncoder().encode(spec))
        #expect(decoded == spec)
    }

    @Test func aCellThatHasAPriceStillGetsTheLeadTimeWhenNoStartDateIsGiven() throws {
        let spec = PlanSpec.regular(RegularPlanSpec(subscriptionIds: ["s"], planType: .upfront,
                                                    prices: [TerritoryAmount(territory: "USA", amount: d("34.99"))],
                                                    startDate: nil, preserveCurrentPrice: true, skipIntroReplacement: [:], filter: PlanFilter()))
        let draft = try plan(spec, yearly().snapshot())
        guard case let .createRegularPrice(price) = draft.items.first?.payload else { Issue.record("no POST"); return }
        #expect(price.startDate == today.adding(days: AppleConstants.minLeadDays))
    }
}
