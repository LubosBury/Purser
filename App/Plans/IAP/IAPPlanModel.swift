import Foundation
import Observation
import Domain
import Catalog
import Importer
import Planner

@MainActor @Observable
final class IAPPlanModel {
    enum Source: String, CaseIterable, Identifiable {
        case table = "Table", csv = "CSV by the workspace mapping"
        var id: String { rawValue }
    }

    let snapshot: CatalogSnapshot
    let config: WorkspaceConfig
    let today: CalendarDate
    @ObservationIgnored private let planning: PlanningModel
    @ObservationIgnored private let planner: Planner
    @ObservationIgnored private let names: TerritoryNameMap

    var iapId: String?
    var baseTerritory: TerritoryCode = "USA"
    var source: Source = .table
    var tableText = ""
    var startDateEnabled = false
    var startDate = Date()
    var reason = ""
    private(set) var csvAmounts: [TerritoryAmount] = []
    private(set) var csvStatus: String?
    private(set) var tableErrors: [PastedAmountLineError] = []
    private(set) var draft: PlanDraft?
    private(set) var lastSpec: PlanSpec?
    private(set) var buildError: String?

    init(planning: PlanningModel, snapshot: CatalogSnapshot) {
        self.planning = planning
        self.snapshot = snapshot
        self.config = planning.config
        self.today = planning.today
        self.planner = planning.sharedPlanner
        self.names = planning.names
    }

    /// nil while the workspace has no snapshot yet.
    static func make(planning: PlanningModel) -> IAPPlanModel? {
        guard let snapshot = planning.snapshot else { return nil }
        return IAPPlanModel(planning: planning, snapshot: snapshot)
    }

    var iaps: [IAPInfo] { snapshot.iaps.values.sorted { $0.productId < $1.productId } }
    var territories: [TerritoryCode] { snapshot.territories.keys.sorted() }
    var currentSchedule: IAPSchedule? { iapId.flatMap { snapshot.iapSchedules[$0] } }

    var inputsFingerprint: String {
        [iapId ?? "", baseTerritory.rawValue, source.rawValue, tableText, csvAmounts.map { "\($0.territory)=\($0.amount)" }.joined(separator: ","),
         String(startDateEnabled), String(startDate.timeIntervalSince1970)].joined(separator: "|")
    }

    func selectIAP(_ id: String?) {
        iapId = id
        if let base = currentSchedule?.baseTerritory { baseTerritory = base }
        csvAmounts = []
        csvStatus = nil
    }

    var diff: IAPScheduleDiff? {
        guard let draft else { return nil }
        for item in draft.items {
            if case let .replaceIAPSchedule(target) = item.payload {
                return IAPScheduleDiff.make(before: currentSchedule, after: target, pricePoints: snapshot.pricePoints,
                                            allTerritories: Set(snapshot.territories.keys), today: today)
            }
        }
        return nil
    }

    var l3Verdicts: [Verdict] { (draft?.verdicts ?? []).filter { $0.rule == "L3" } }
    var planBlockingVerdicts: [Verdict] { (draft?.verdicts ?? []).filter { $0.severity == .block(.plan) } }
    var canSave: Bool { (draft.map { !$0.items.isEmpty } ?? false) && lastSpec != nil && planBlockingVerdicts.isEmpty }

    func loadCSV(from url: URL) async {
        guard let iapId, let mapping = config.importMapping else {
            csvStatus = "Select an IAP and set the import mapping in the workspace."
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let (table, verdicts) = try await Importer(names: names).importTable(source: CSVTableSource(data: data), mapping: mapping,
                                                                                  territories: snapshot.territories)
            let blocks = verdicts.filter { if case .block = $0.severity { return true } else { return false } }
            guard blocks.isEmpty else {
                csvAmounts = []
                csvStatus = blocks.map { "\($0.rule.rawValue): \($0.message)" }.joined(separator: "\n")
                return
            }
            csvAmounts = IAPImportExtractor.amounts(from: table, mapping: mapping, iapId: iapId)
            csvStatus = csvAmounts.isEmpty ? "The mapping has no “IAP price” column for this IAP."
                                           : "Loaded \(csvAmounts.count) manual prices from the mapped column."
        } catch {
            csvAmounts = []
            csvStatus = String(describing: error)
        }
    }

    private func amounts() -> [TerritoryAmount]? {
        switch source {
        case .csv:
            return csvAmounts.isEmpty ? nil : csvAmounts
        case .table:
            let parsed = PastedAmountTable.parse(tableText, names: names, known: Set(snapshot.territories.keys))
            tableErrors = parsed.errors
            return parsed.errors.isEmpty && !parsed.amounts.isEmpty ? parsed.amounts : nil
        }
    }

    var baseHasManualPrice: Bool {
        switch source {
        case .csv: return csvAmounts.contains { $0.territory == baseTerritory }
        case .table: return PastedAmountTable.parse(tableText, names: names, known: Set(snapshot.territories.keys)).amounts.contains { $0.territory == baseTerritory }
        }
    }

    /// Called debounced from the view; never from `body`.
    func rebuild() {
        tableErrors = []
        guard let iapId, let amounts = amounts() else { draft = nil; lastSpec = nil; buildError = nil; return }
        let start = startDateEnabled ? CalendarDate.today(now: startDate) : nil
        let spec = PlanSpec.iap(IAPPlanSpec(iapId: iapId, baseTerritory: baseTerritory, prices: amounts, startDate: start))
        do {
            draft = try planner.plan(spec, context: PlanningContext(snapshot: snapshot, config: config, today: today))
            lastSpec = spec
            buildError = nil
        } catch {
            draft = nil
            lastSpec = nil
            buildError = String(describing: error)
        }
    }

    /// Stores the Draft through PlanningModel.build and opens the Plan screen. nil on success, else the message to show.
    func save() async -> String? {
        guard canSave, let lastSpec else { return "The plan is not built." }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if await planning.build(lastSpec, reason: trimmed.isEmpty ? nil : trimmed) { return nil }
        let message = planning.errorMessage ?? "The plan cannot be saved."
        planning.errorMessage = nil
        return message
    }
}
