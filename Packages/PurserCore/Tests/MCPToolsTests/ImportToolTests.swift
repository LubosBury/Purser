import Foundation
import Testing
import Domain
import Catalog
import Importer
import Policy
import Planner
import MCPBridge
@testable import MCPTools
import PurserTestSupport

private func d(_ text: String) -> Decimal { Decimal(string: text)! }

/// The path create_import_plan takes: the workspace template, edited as CSV text, through the Importer into a plan.
@Suite struct ImportToolTests {
    private let products = [ImportTemplate.Product(ascId: "s", productId: "com.example.s"), ImportTemplate.Product(ascId: "t", productId: "com.example.t")]

    private func snapshot() -> CatalogSnapshot {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": d("29.99"), "DEU": d("29.99")])
        catalog.addSubscription("t", prices: ["USA": d("9.99"), "DEU": d("9.99")])
        return catalog.snapshot()
    }

    private func template(_ snapshot: CatalogSnapshot) throws -> String {
        try ImportTemplate.csv(products: products, territories: snapshot.territories,
                               prices: ["s": ["USA": d("29.99"), "DEU": d("29.99")], "t": ["USA": d("9.99"), "DEU": d("9.99")]]).text
    }

    private func imported(_ csv: String, _ snapshot: CatalogSnapshot) async throws -> (ImportedTable, [Verdict]) {
        try await Importer(names: try TerritoryNameMap.bundled())
            .importTable(source: CSVTableSource(data: Data(csv.utf8)), mapping: ImportTemplate.mapping(products: products, version: 1),
                         territories: snapshot.territories)
    }

    @Test func anEditedTemplateBecomesOnePlanForEveryProduct() async throws {
        let snapshot = snapshot()
        let csv = try template(snapshot).replacingOccurrences(of: "United States,USD,29.99,9.99", with: "United States,USD,34.99,9.99")
        #expect(csv.contains("34.99"))
        let (table, verdicts) = try await imported(csv, snapshot)
        #expect(verdicts.isEmpty)
        let mapping = ImportTemplate.mapping(products: products, version: 1)
        let spec = try PlanArguments(["preserve_current_price": true, "start_date": "2026-11-01"], snapshot: snapshot).importTable(table, mapping: mapping)
        guard case let .importTable(importSpec) = spec else { Issue.record("spec"); return }
        #expect(importSpec.writeColumns == ["C", "D"])
        #expect(importSpec.preserveCurrentPrice == true)
        #expect(!importSpec.canary)
        let draft = try Planner(policy: PolicyEngine()).plan(spec, context: PlanningContext(snapshot: snapshot, config: SyntheticCatalog.config(mapping: mapping),
                                                                                           today: SyntheticCatalog.today))
        // Only the one edited cell changes; the three unchanged prices produce nothing.
        #expect(draft.items.count == 1)
        #expect(draft.items.first?.cell == .regular(subscriptionId: "s", territory: "USA", planType: .upfront))
    }

    @Test func aWrongCurrencyIsRefusedByTheImporter() async throws {
        let snapshot = snapshot()
        let csv = try template(snapshot).replacingOccurrences(of: "Germany,USD", with: "Germany,EUR")
        let (_, verdicts) = try await imported(csv, snapshot)
        #expect(verdicts.map(\.rule) == ["S2"])
        #expect(verdicts.allSatisfy { $0.severity == .block(.plan) })
    }

    @Test func writeColumnsAndProductsNarrowThePlan() async throws {
        let snapshot = snapshot()
        let (table, _) = try await imported(try template(snapshot), snapshot)
        let mapping = ImportTemplate.mapping(products: products, version: 1)
        guard case let .importTable(spec) = try PlanArguments(["write_columns": ["d"], "products": ["com.example.t"], "territories": ["USA"], "canary": true],
                                                              snapshot: snapshot).importTable(table, mapping: mapping) else { Issue.record("spec"); return }
        #expect(spec.writeColumns == ["D"])
        #expect(spec.filter == PlanFilter(productAscIds: ["t"], territories: ["USA"]))
        #expect(spec.canary)
        #expect(throws: ToolArgumentError.self) {
            _ = try PlanArguments(["write_columns": ["Z"]], snapshot: snapshot).importTable(table, mapping: mapping)
        }
        var checkOnly = mapping
        checkOnly.targets = checkOnly.targets.map { var target = $0; target.writes = false; return target }
        #expect(throws: ToolArgumentError.self) {
            _ = try PlanArguments([:], snapshot: snapshot).importTable(table, mapping: checkOnly)
        }
    }

    /// A hand-made mapping: data from row 3, country in B, currency in A, a regular column, a check-only column and an
    /// in-app purchase column.
    private func customMapping() -> ImportMapping {
        ImportMapping(version: 7, source: .csv, firstDataRow: 3, countryColumn: "B", currencyColumn: "A", targets: [
            ImportTarget(column: "D", productAscId: "s", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: true),
            ImportTarget(column: "E", productAscId: "t", kind: .regularPrice(planType: .upfront), nominalDiscount: nil, writes: false),
            ImportTarget(column: "F", productAscId: "life", kind: .iapManualPrice, nominalDiscount: nil, writes: true),
        ])
    }

    private func customSnapshot() -> CatalogSnapshot {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": d("29.99"), "DEU": d("29.99")])
        catalog.addSubscription("t", prices: ["USA": d("9.99")], available: ["USA", "DEU"])
        catalog.addIAP("life", base: "USA", manual: ["USA": d("49.99"), "DEU": d("44.99")])
        return catalog.snapshot()
    }

    private func read(_ csv: String, _ mapping: ImportMapping, _ snapshot: CatalogSnapshot,
                      empty: EmptyWrittenCells = .skip) async throws -> (ImportedTable, [Verdict]) {
        try await Importer(names: try TerritoryNameMap.bundled())
            .importTable(source: CSVTableSource(data: Data(csv.utf8)), mapping: mapping, territories: snapshot.territories, emptyWrittenCells: empty)
    }

    @Test func theExportFollowsTheSavedMappingAndPlansNothingWhenUnedited() async throws {
        let snapshot = customSnapshot()
        let mapping = customMapping()
        let export = try ImportTableExport.csv(mapping: mapping, snapshot: snapshot, today: SyntheticCatalog.today)
        let lines = export.text.components(separatedBy: "\r\n")
        #expect(lines[0] == ",,,,,")
        #expect(lines[1] == "Currency,Country,,com.example.s regular,com.example.t regular (check only),com.example.life manual price")
        #expect(lines.contains("USD,Germany,,29.99,,44.99"))
        #expect(lines.contains("USD,United States,,29.99,9.99,49.99"))
        #expect(export.emptyCells == 0)

        let (table, verdicts) = try await read(export.text, mapping, snapshot)
        #expect(verdicts.isEmpty)
        let spec = try PlanArguments([:], snapshot: snapshot).importTable(table, mapping: mapping)
        guard case let .importTable(importSpec) = spec else { Issue.record("spec"); return }
        #expect(importSpec.writeColumns == ["D", "F"])
        #expect(ImportChecks.removedManualPrices(spec: importSpec, mapping: mapping, snapshot: snapshot, today: SyntheticCatalog.today).isEmpty)
        let draft = try Planner(policy: PolicyEngine()).plan(spec, context: PlanningContext(snapshot: snapshot, config: SyntheticCatalog.config(mapping: mapping),
                                                                                           today: SyntheticCatalog.today))
        #expect(draft.items.isEmpty)
        #expect(draft.checkDiffs.isEmpty)
    }

    @Test func anEmptyCellIsSkippedWithAWarningOverMCPAndRefusedInTheApp() async throws {
        let snapshot = customSnapshot()
        let mapping = customMapping()
        let csv = try ImportTableExport.csv(mapping: mapping, snapshot: snapshot, today: SyntheticCatalog.today).text
            .replacingOccurrences(of: "USD,Germany,,29.99,,44.99", with: "USD,Germany,,,,44.99")
        let (table, skipped) = try await read(csv, mapping, snapshot)
        #expect(skipped.map(\.severity) == [.warn])
        #expect(skipped.first?.message.contains("column D") == true)
        #expect(table.row(for: "DEU")?.values["D"] == nil)
        #expect(table.row(for: "USA")?.values["D"] == .amount(d("29.99")))
        let (_, refused) = try await read(csv, mapping, snapshot, empty: .refuse)
        #expect(refused.contains { $0.rule == "S3" && $0.severity == .block(.plan) })
    }

    @Test func aBlankedOrMissingIAPCellIsReportedAsARemovedManualPrice() async throws {
        let snapshot = customSnapshot()
        let mapping = customMapping()
        let export = try ImportTableExport.csv(mapping: mapping, snapshot: snapshot, today: SyntheticCatalog.today).text
        let removed = [ImportChecks.RemovedManualPrice(iapId: "life", territory: "DEU", price: d("44.99"))]

        let blanked = export.replacingOccurrences(of: "USD,Germany,,29.99,,44.99", with: "USD,Germany,,29.99,,")
        let (blankedTable, _) = try await read(blanked, mapping, snapshot)
        guard case let .importTable(blankedSpec) = try PlanArguments([:], snapshot: snapshot).importTable(blankedTable, mapping: mapping) else { Issue.record("spec"); return }
        #expect(ImportChecks.removedManualPrices(spec: blankedSpec, mapping: mapping, snapshot: snapshot, today: SyntheticCatalog.today) == removed)

        let withoutRow = export.replacingOccurrences(of: "USD,Germany,,29.99,,44.99\r\n", with: "")
        let (shortTable, _) = try await read(withoutRow, mapping, snapshot)
        guard case let .importTable(shortSpec) = try PlanArguments([:], snapshot: snapshot).importTable(shortTable, mapping: mapping) else { Issue.record("spec"); return }
        #expect(ImportChecks.removedManualPrices(spec: shortSpec, mapping: mapping, snapshot: snapshot, today: SyntheticCatalog.today) == removed)
        #expect(ImportChecks.territoriesWithoutARow(table: shortTable, snapshot: snapshot) == ["DEU"])

        // Not writing the in-app purchase column leaves its schedule alone.
        guard case let .importTable(regularOnly) = try PlanArguments(["write_columns": ["D"]], snapshot: snapshot).importTable(shortTable, mapping: mapping) else {
            Issue.record("spec"); return
        }
        #expect(ImportChecks.removedManualPrices(spec: regularOnly, mapping: mapping, snapshot: snapshot, today: SyntheticCatalog.today).isEmpty)

        let report = ImportChecks.report(spec: shortSpec, mapping: mapping, snapshot: snapshot, today: SyntheticCatalog.today) { "Name of \($0)" }
        #expect(report["iap_manual_prices_removed"] == [["product": "Name of life", "territory": "DEU", "current_price": .number(44.99)]])
        #expect(report["territories_without_a_row"] == ["DEU"])
        #expect(report["warning"] != nil)
    }

    @Test func theFormatNamesEveryColumn() {
        var mapping = ImportTemplate.mapping(products: products, version: 3)
        mapping.targets.append(ImportTarget(column: "e", productAscId: "s", kind: .introPayUpFront(duration: .oneYear), nominalDiscount: d("0.2"), writes: false))
        let format = MCPRender.importMapping(mapping) { "Name of \($0)" }
        #expect(format["mapping_version"] == 3)
        #expect(format["first_data_row"] == 2)
        #expect(format["country_column"] == "A")
        #expect(format["currency_column"] == "B")
        let columns = format["columns"]?.arrayValue ?? []
        #expect(columns.map { $0["column"] } == ["C", "D", "E"])
        #expect(columns[0]["product"] == "Name of s")
        #expect(columns[0]["written"] == true)
        #expect(columns[2]["written"] == false)
        #expect(columns[2]["holds"] == "intro offer PAY_UP_FRONT ONE_YEAR")
        #expect(columns[2]["nominal_discount_percent"] == 20)
    }

    @Test func checkDifferencesAreListedUpToTheLimit() {
        let diff = CheckDiff(column: "E", cell: .regular(subscriptionId: "s", territory: "USA", planType: .upfront), imported: d("30"),
                             snapped: d("29.99"), live: nil)
        let rendered = MCPRender.checkDiffs(Array(repeating: diff, count: 5), limit: 2)
        #expect(rendered.arrayValue?.count == 2)
        #expect(rendered.arrayValue?.first == ["column": "E", "cell": "R|s|USA|UPFRONT", "imported": 30, "snapped": .number(29.99), "live": nil])
    }
}
