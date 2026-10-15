import Foundation
import Testing
import Domain
import Catalog
import Importer
import Policy
@testable import Planner
import PurserTestSupport

@Suite struct PlanDiffTests {
    @Test func textCellsDescribeLocaleTextsAndVersion() {
        let owner = LocalizationOwner.subscription("s")
        let live = LocalizationRow(ascId: "loc-1", owner: owner, versionId: "ver-1", locale: "en-US",
                                   text: LocalizationText(name: "Yearly", description: "Every fruit"))
        let pending = LocalizationRow(ascId: "loc-2", owner: owner, versionId: "ver-2", locale: "en-US",
                                      text: LocalizationText(name: "Yearly Plus", description: "Every fruit, all year"))
        let version = MetadataVersion(ascId: "ver-2", owner: owner, number: 2, state: .prepareForSubmission)
        #expect(PlanDiff.describe(.localization(live: live, pending: nil, pendingVersion: nil)) == "en-US: Yearly — Every fruit")
        #expect(PlanDiff.describe(.localization(live: live, pending: pending, pendingVersion: version))
                == "en-US: Yearly — Every fruit → en-US: Yearly Plus — Every fruit, all year (version 2, PREPARE_FOR_SUBMISSION)")
        #expect(PlanDiff.describe(.localization(live: nil, pending: nil, pendingVersion: nil)) == "—")
        let group = LocalizationRow(ascId: "loc-3", owner: .group("g"), versionId: "ver-3", locale: "cs",
                                    text: LocalizationText(name: "Prémium", customAppName: "Ovoce"))
        #expect(PlanDiff.describe(.localization(live: group, pending: nil, pendingVersion: nil)) == "cs: Prémium — Ovoce")
        #expect(PlanDiff.describe(.metadataVersion(version)) == "version 2, PREPARE_FOR_SUBMISSION")
        #expect(PlanDiff.describe(.metadataVersion(nil)) == "—")
    }

    @Test func introRowsShowPriceDiscountAndShareOfRegular() throws {
        let snapshot = yearly(.approved).snapshot()
        let spec = introSpec(.percentOfRegular(d("0.8")), start: today.adding(days: 7), territories: ["USA", "DEU"])
        let draft = try plan(spec, snapshot)
        let rows = PlanDiff.rows(items: draft.items, verdicts: draft.verdicts, spec: spec, snapshot: snapshot,
                                 config: SyntheticCatalog.config(), today: today)
        #expect(rows.map(\.territory) == ["DEU", "USA"])
        #expect(rows[0].currency == "USD")
        #expect(rows[0].before == "—")
        #expect(rows[0].after == "PUF ONE_YEAR 23.99 from \(today.adding(days: 7))")
        #expect(rows[0].afterPrice == d("23.99"))
        #expect(rows[0].percentOfRegular == d("23.99") / d("29.99"))
        #expect(rows[0].effectiveDiscount == 1 - d("23.99") / d("29.99"))
        #expect(rows[0].date == today.adding(days: 7))
        #expect(!rows[0].isMarked)
    }

    @Test func regularRowsShowDeltaAndMarkedFlagsFollowVerdicts() throws {
        let snapshot = yearly().snapshot()
        let spec = regularSpec(["USA": "24.99"], preserve: nil)
        let draft = try plan(spec, snapshot)
        let rows = PlanDiff.rows(items: draft.items, verdicts: draft.verdicts, spec: spec, snapshot: snapshot,
                                 config: SyntheticCatalog.config(), today: today)
        #expect(rows.count == 1)
        #expect(rows[0].before == "29.99")
        #expect(rows[0].after == "29.99 → 24.99 from \(today.adding(days: 7))")
        #expect(rows[0].deltaPercent == (d("24.99") - d("29.99")) / d("29.99"))
        #expect(rows[0].isMarked)
        #expect(rows[0].verdicts.map(\.rule) == ["R7"])
    }

    @Test func importedValuesAppearInRows() async throws {
        let (table, _) = try await SyntheticImport.importedTable()
        let snapshot = SyntheticCatalog.fromSyntheticTable(table).snapshot()
        let config = SyntheticCatalog.config(mapping: SyntheticImport.mapping())
        let spec = PlanSpec.importTable(ImportPlanSpec(table: table, writeColumns: ["D"], filter: PlanFilter(territories: ["KOR"]),
                                                       startDate: today.adding(days: 7), preserveCurrentPrice: nil, canary: false))
        let draft = try plan(spec, snapshot, config: config)
        let rows = PlanDiff.rows(items: draft.items, verdicts: draft.verdicts, spec: spec, snapshot: snapshot, config: config, today: today)
        #expect(rows.count == 1)
        #expect(rows[0].importedValue == table.row(for: "KOR")?.values["D"]?.amount)
        #expect(rows[0].currency == "KRW")
        #expect(rows[0].isMarked)
    }

    @Test func pastedTablesAcceptCodesNamesAndSeparators() throws {
        let names = try TerritoryNameMap.bundled()
        let parsed = PastedTable.amounts("USA 34.99\nKorea, Republic of\t39.99\nCZE;24.99\nNarnia 1\nDEU 1,99\n\n", names: names)
        #expect(parsed.amounts == [TerritoryAmount(territory: "USA", amount: d("34.99")), TerritoryAmount(territory: "KOR", amount: d("39.99")),
                                   TerritoryAmount(territory: "CZE", amount: d("24.99"))])
        #expect(parsed.errors == ["row 4: unknown territory “Narnia”", "row 5: “1,99” is not a number > 0"])
        let trials = PastedTable.durations("USA ONE_MONTH\nDEU 14", names: names)
        #expect(trials.durations == ["USA": .oneMonth, "DEU": .twoWeeks])
        #expect(PastedTable.territories("", names: names).territories == nil)
        #expect(PastedTable.territories("USA, Czech Republic", names: names).territories == ["USA", "CZE"])
    }
}
