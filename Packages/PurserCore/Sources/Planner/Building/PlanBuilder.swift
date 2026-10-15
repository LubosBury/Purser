import Foundation
import Domain
import Catalog
import Policy

/// Turns a PlanSpec into items: collects regular and intro intents per cell, emits product-level items
/// (promo, IAP, withdraw) directly, then emits the cell chains in a stable order (subscription, territory).
struct PlanBuilder {
    let context: PlanningContext
    let snapper: Snapper
    var sink = ItemSink()
    var verdicts: [Verdict] = []
    var checkDiffs: [CheckDiff] = []
    var regularIntents: [PriceKey: RegularIntent] = [:]
    var introIntents: [PriceKey: IntroIntent] = [:]
    var summary: PlanSpecSummary
    var missingPreserve = 0
    /// Seqs of PATCH_PRICES items on PAY_AS_YOU_GO promos per subscription (O5 ordering before regular decreases).
    var paygPromoPatches: [String: [Int]] = [:]

    var snapshot: CatalogSnapshot { context.snapshot }
    var today: CalendarDate { context.today }

    init(context: PlanningContext, origin: PlanOrigin) {
        self.context = context
        self.snapper = Snapper(index: context.snapshot.pricePoints)
        self.summary = PlanSpecSummary(origin: origin, canary: false, nominalDiscounts: [:], skippedIntroReplacements: [:],
                                       effectiveLiveIntroCanaryProducts: context.effectiveLiveIntroCanaryProducts)
    }

    mutating func build(_ spec: PlanSpec) throws {
        try collect(spec)
        if missingPreserve > 0 { throw PlanningError.preserveChoiceMissing(increases: missingPreserve) }
        addAutomaticIntroReplacements()
        emitPriceCells()
    }

    private mutating func collect(_ spec: PlanSpec) throws {
        switch spec {
        case let .importTable(s): try addImport(s)
        case let .regular(s): addRegular(s)
        case let .intro(s): addIntro(s)
        case let .promo(s): addPromo(s)
        case let .iap(s): addIAP(s)
        case let .withdraw(s): try addWithdraw(s)
        case let .localization(s): addLocalization(s)
        case let .fix(_, underlying): try collect(underlying)
        }
    }

    // MARK: helpers shared by the builders

    func subscription(_ ascId: String) -> SubscriptionInfo? { snapshot.subscriptions[ascId] }

    mutating func requireSubscription(_ ascId: String) -> SubscriptionInfo? {
        if let sub = snapshot.subscriptions[ascId] { return sub }
        verdicts.append(Verdict(rule: PlannerRule.plan, severity: .block(.plan), cell: nil, message: "The subscription \(ascId) is not in the catalog."))
        return nil
    }

    mutating func snap(_ amount: Decimal, product: String, territory: TerritoryCode, planType: PlanType?,
                       direction: SnapDirection, cell: CellKey) -> PricePoint? {
        switch snapper.snap(amount, productAscId: product, territory: territory, planType: planType, direction: direction, cell: cell) {
        case let .snapped(result):
            if let warning = result.warning { verdicts.append(warning) }
            return result.point
        case let .blocked(verdict):
            verdicts.append(verdict)
            return nil
        }
    }

    mutating func unavailable(_ cell: CellKey, _ territory: TerritoryCode) {
        verdicts.append(Verdict(rule: "A6", severity: .block(.cell), cell: cell, message: "The territory \(territory) is outside the product's availability."))
    }

    // MARK: cell chains

    mutating func emitPriceCells() {
        for key in Set(regularIntents.keys).union(introIntents.keys).sorted() {
            let regular = regularIntents[key]
            let intro = introIntents[key]
            if regular?.direction == .decrease {
                let introLast = emitIntroChain(intro, after: [])
                emitRegularChain(regular, after: (introLast.map { [$0] } ?? []) + (paygPromoPatches[key.subscriptionId] ?? []))
            } else {
                let regularLast = emitRegularChain(regular, after: [])
                emitIntroChain(intro, after: regularLast.map { [$0] } ?? [])
            }
        }
    }
}
