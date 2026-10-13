import Foundation
import Testing
import Domain
import Catalog
import Policy
@testable import Planner
import PurserTestSupport

@Suite struct FixPrefillTests {
    @Test func i4GroupPrefillsAnIntroFixPlan() throws {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": d("29.99"), "DEU": d("29.99"), "CZE": d("29.99")], state: .readyToSubmit)
        catalog.addIntro("s", "USA", price: d("31.99"))
        catalog.addIntro("s", "DEU", price: d("31.99"))
        catalog.addIntro("s", "CZE", price: d("23.99"))
        let snapshot = catalog.snapshot()
        let findings = try FindingFactory.records(PolicyEngine().invariants(snapshot, today: today))
        let group = try #require(FindingGroups.group(findings).first)
        let config = SyntheticCatalog.config(mapping: ImportMapping(version: 1, source: .csv, firstDataRow: 2, countryColumn: "A", currencyColumn: "B", targets: [
            ImportTarget(column: "D", productAscId: "s", kind: .introPayUpFront(duration: .oneYear), nominalDiscount: d("0.2"), writes: true),
        ]))
        let prefill = try #require(FixPrefill.forGroup(group, snapshot: snapshot, config: config, today: today))
        #expect(prefill.territories == ["USA", "DEU"])
        #expect(prefill.mode == .payUpFront && prefill.duration == .oneYear && prefill.numberOfPeriods == 1)
        #expect(prefill.nominalDiscount == d("0.2"))
        let draft = try plan(prefill.spec(pricing: .percentOfRegular(d("0.8")), startDate: nil, canary: false), snapshot, config: config)
        #expect(draft.spec.origin == .fix)
        #expect(draft.ops == [.delete, .post, .delete, .post])
        #expect(draft.blocks.isEmpty)
        #expect(PolicyEngine().invariants(snapshot, today: today).count == 2)
    }

    @Test func otherRulesHaveNoPrefill() {
        let group = FindingGroup(type: .invariant, rule: "R3", productAscId: "s", findings: [])
        #expect(FixPrefill.forGroup(group, snapshot: SyntheticCatalog().snapshot(), config: SyntheticCatalog.config(), today: today) == nil)
    }
}
