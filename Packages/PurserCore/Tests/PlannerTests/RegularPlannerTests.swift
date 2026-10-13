import Foundation
import Testing
import Domain
import Catalog
import Importer
import Policy
@testable import Planner
import PurserTestSupport

@Suite struct RegularPlannerTests {
    @Test func increaseWithPreserveIsOnePost() throws {
        let draft = try plan(regularSpec(["USA": "34.99"]), yearly().snapshot())
        #expect(draft.ops == [.post])
        guard case let .createRegularPrice(price) = draft.items[0].payload else { Issue.record("payload"); return }
        #expect(price.preserveCurrentPrice)
        #expect(price.startDate == today.adding(days: 7))
        #expect(price.pricePointId == SyntheticCatalog.pointId("s", "USA", .upfront, d("34.99")))
        #expect(draft.blocks.isEmpty)
        #expect(draft.spec.origin == .regular)
    }

    @Test func increaseWithoutPreserveChoiceBlocksPlan() throws {
        let draft = try plan(regularSpec(["USA": "34.99", "DEU": "39.99", "CZE": "24.99"], preserve: nil), yearly().snapshot())
        #expect(draft.items.isEmpty)
        #expect(draft.verdicts.map(\.severity) == [.block(.plan)])
        #expect(draft.verdicts[0].rule == "R1")
        #expect(draft.verdicts[0].message.hasPrefix("R1 preserve choice missing"))
        #expect(draft.verdicts[0].message.contains("2 regular price increases"))
    }

    @Test func decreaseNeverPreservesAndNeedsC2() throws {
        let draft = try plan(regularSpec(["USA": "24.99"], preserve: nil), yearly().snapshot())
        guard case let .createRegularPrice(price) = draft.items.first?.payload else { Issue.record("payload"); return }
        #expect(!price.preserveCurrentPrice)
        #expect(draft.confirmationLevel == .c2)
        #expect(draft.verdicts("R7").count == 1)
    }

    @Test func unchangedPriceProducesNoItem() throws {
        let draft = try plan(regularSpec(["USA": "29.99", "DEU": "30.20"]), yearly().snapshot())
        #expect(draft.items.isEmpty)
    }

    @Test func scheduledChangeIsReplacedByDeleteThenPost() throws {
        var catalog = yearly()
        catalog.setRegular("s", "USA", d("31.99"), start: today.adding(days: 20), ascId: "rp-future")
        let draft = try plan(regularSpec(["USA": "34.99"]), catalog.snapshot())
        #expect(draft.ops == [.delete, .post])
        #expect(draft.items[0].payload == .deleteRegularPrice(ascId: "rp-future"))
        #expect(draft.items[1].dependsOn == [1])
        #expect(draft.items[1].before == draft.items[0].target)
        #expect(draft.items.allSatisfy { $0.rules.contains("R5") })
        #expect(draft.verdicts("R5").map(\.severity) == [.confirm(.c2)])
    }

    @Test func missingStartDateDefaultsToLeadTimeInImport() throws {
        let mapping = ImportMapping(version: 1, source: .csv, firstDataRow: 2, countryColumn: "A", currencyColumn: "B", targets: [
            ImportTarget(column: "C", productAscId: "s", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: true),
        ])
        let table = ImportedTable(mappingVersion: 1, sha256: "x", rows: [
            ImportedRow(rowNumber: 2, territory: "USA", currency: "USD", values: ["C": .amount(d("34.99"))]),
            ImportedRow(rowNumber: 3, territory: "CZE", currency: "USD", values: ["C": .amount(d("29.99"))]),
        ], rawRows: [])
        let spec = PlanSpec.importTable(ImportPlanSpec(table: table, writeColumns: ["C"], filter: PlanFilter(), startDate: nil,
                                                       preserveCurrentPrice: true, canary: false))
        let draft = try plan(spec, yearly().snapshot(), config: SyntheticCatalog.config(mapping: mapping))
        #expect(draft.ops == [.post])
        guard case let .createRegularPrice(price) = draft.items[0].payload else { Issue.record("payload"); return }
        #expect(price.territory == "USA")
        #expect(price.startDate == today.adding(days: AppleConstants.minLeadDays))
        #expect(draft.spec.origin == .importTable)
    }

    @Test func decreaseWithPaidIntroReplacesIntroFirstWithSameStartDate() throws {
        var catalog = yearly(.readyToSubmit)
        catalog.addIntro("s", "USA", price: d("23.99"))
        let start = today.adding(days: 7)
        let draft = try plan(regularSpec(["USA": "19.99"], start: start), catalog.snapshot())
        #expect(draft.ops == [.delete, .post, .post])
        #expect(draft.items.map(\.cell) == [.intro(subscriptionId: "s", territory: "USA", planType: .upfront),
                                            .intro(subscriptionId: "s", territory: "USA", planType: .upfront),
                                            .regular(subscriptionId: "s", territory: "USA", planType: .upfront)])
        #expect(draft.items[1].dependsOn == [1])
        #expect(draft.items[2].dependsOn == [2])
        guard case let .createIntro(offer) = draft.items[1].payload else { Issue.record("payload"); return }
        #expect(offer.startDate == start)
        // 23.99 x 19.99 / 29.99 = 15.99... -> floor 15.99
        #expect(offer.pricePointId == SyntheticCatalog.pointId("s", "USA", .upfront, d("15.99")))
        #expect(draft.items[1].rules.contains("I8"))
        #expect(draft.verdicts("I8").isEmpty)
        #expect(draft.verdicts("I4").isEmpty)
    }

    @Test func futureIntroIsReplacedFromItsOwnStartDate() throws {
        var catalog = yearly(.readyToSubmit)
        let introStart = today.adding(days: 30)
        catalog.addIntro("s", "USA", price: d("23.99"), start: introStart, ascId: "io-later")
        let draft = try plan(regularSpec(["USA": "34.99"]), catalog.snapshot())
        #expect(draft.ops == [.post, .delete, .post])
        #expect(draft.items[1].payload == .deleteIntro(ascId: "io-later"))
        guard case let .createIntro(offer) = draft.items[2].payload else { Issue.record("payload"); return }
        #expect(offer.startDate == introStart)
        // 23.99 x 34.99 / 29.99 = 27.989 -> highest point below is 26.99
        #expect(offer.pricePointId == SyntheticCatalog.pointId("s", "USA", .upfront, d("26.99")))
        #expect(draft.verdicts("I8").isEmpty)
    }

    @Test func increaseWithPaidIntroWritesRegularFirst() throws {
        var catalog = yearly(.readyToSubmit)
        catalog.addIntro("s", "USA", price: d("23.99"))
        let draft = try plan(regularSpec(["USA": "39.99"]), catalog.snapshot())
        #expect(draft.items.map(\.cell.storageKey) == ["R|s|USA|UPFRONT", "I|s|USA|UPFRONT", "I|s|USA|UPFRONT"])
        #expect(draft.ops == [.post, .delete, .post])
        #expect(draft.items[1].dependsOn == [1])
    }

    @Test func liveIntroOnApprovedProductIsEndedAndReplacedButBlockedUntilS4b() throws {
        var catalog = yearly(.approved)
        catalog.addIntro("s", "USA", price: d("23.99"))
        let start = today.adding(days: 7)
        let draft = try plan(regularSpec(["USA": "19.99"], start: start), catalog.snapshot())
        #expect(draft.ops == [.patchEnd, .post, .post])
        #expect(draft.items[0].payload == .endIntro(ascId: "io-s-USA-2026-01-01", endDate: start))
        #expect(draft.verdicts("I7").map(\.severity) == [.block(.plan)])
    }

    @Test func skippedReplacementNeedsC2() throws {
        var catalog = yearly(.readyToSubmit)
        catalog.addIntro("s", "USA", price: d("23.99"))
        let introCell: CellKey = .intro(subscriptionId: "s", territory: "USA", planType: .upfront)
        let draft = try plan(regularSpec(["USA": "34.99"], skip: [introCell: "keeping the intro after the increase"]), catalog.snapshot())
        #expect(draft.ops == [.post])
        #expect(draft.verdicts("I8").map(\.severity) == [.confirm(.c2)])
        #expect(draft.confirmationLevel == .c2)
    }

}
