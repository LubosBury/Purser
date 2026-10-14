import Foundation
import Domain
import Catalog
import ASCClient
@testable import Policy
import PurserTestSupport

let today = SyntheticCatalog.today
func d(_ text: String) -> Decimal { Decimal(string: text)! }

func context(_ snapshot: CatalogSnapshot, _ items: [PlannedItem], config: WorkspaceConfig = SyntheticCatalog.config(),
             origin: PlanOrigin = .importTable, canary: Bool = false, nominal: [String: Decimal] = [:],
             skipped: [CellKey: String] = [:], others: [String] = [], rateLimit: RateLimitSnapshot? = nil,
             unlocked: Set<String> = [], written: [PlannedItem] = []) -> PolicyContext {
    PolicyContext(snapshot: snapshot, config: config, today: today,
                  spec: PlanSpecSummary(origin: origin, canary: canary, nominalDiscounts: nominal, skippedIntroReplacements: skipped,
                                        effectiveLiveIntroCanaryProducts: unlocked),
                  items: items, liveBinding: nil, liveBundleId: nil, otherApplyingPlanIds: others, rateLimit: rateLimit,
                  writtenItems: written)
}

/// One yearly subscription "s" in USA (29.99), DEU (29.99) and CZE (29.99).
func basicCatalog(state: ProductState = .approved, monthly: Bool = false) -> SyntheticCatalog {
    var catalog = SyntheticCatalog()
    catalog.addSubscription("s", prices: ["USA": d("29.99"), "DEU": d("29.99"), "CZE": d("29.99")], state: state, monthly: monthly)
    return catalog
}
