import Foundation
import Domain
import Catalog
import Policy
@testable import Planner
import PurserTestSupport

let today = SyntheticCatalog.today
func d(_ text: String) -> Decimal { Decimal(string: text)! }

func planningContext(_ snapshot: CatalogSnapshot, config: WorkspaceConfig = SyntheticCatalog.config()) -> PlanningContext {
    PlanningContext(snapshot: snapshot, config: config, today: today)
}

func plan(_ spec: PlanSpec, _ snapshot: CatalogSnapshot, config: WorkspaceConfig = SyntheticCatalog.config()) throws -> PlanDraft {
    try Planner(policy: PolicyEngine()).plan(spec, context: planningContext(snapshot, config: config))
}

extension PlanDraft {
    var blocks: [Verdict] { verdicts.filter { if case .block = $0.severity { return true } else { return false } } }
    func verdicts(_ rule: RuleID) -> [Verdict] { verdicts.filter { $0.rule == rule } }
    var ops: [ItemOp] { items.map(\.op) }
}

/// Yearly subscription "s" with 29.99 in USA, DEU, CZE.
func yearly(_ state: ProductState = .approved) -> SyntheticCatalog {
    var catalog = SyntheticCatalog()
    catalog.addSubscription("s", prices: ["USA": d("29.99"), "DEU": d("29.99"), "CZE": d("29.99")], state: state)
    return catalog
}

func regularSpec(_ prices: [TerritoryCode: String], start: CalendarDate = today.adding(days: 7), preserve: Bool? = true,
                 skip: [CellKey: String] = [:]) -> PlanSpec {
    .regular(RegularPlanSpec(subscriptionIds: ["s"], planType: .upfront,
                             prices: prices.map { TerritoryAmount(territory: $0.key, amount: d($0.value)) },
                             startDate: start, preserveCurrentPrice: preserve, skipIntroReplacement: skip, filter: PlanFilter()))
}
