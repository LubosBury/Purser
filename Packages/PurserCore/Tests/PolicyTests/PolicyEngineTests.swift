import Foundation
import Testing
import Domain
import Catalog
import Store
import Audit
import ASCClient
@testable import Policy
import PurserTestSupport

struct FixedRule: PlanRule, InvariantRule {
    var id: RuleID
    var verdicts: [Verdict]
    func evaluate(_ context: PolicyContext) -> [Verdict] { verdicts }
    func check(_ snapshot: CatalogSnapshot, today: CalendarDate) -> [Verdict] { verdicts }
}

func emptyContext(items: [PlannedItem] = [], config: WorkspaceConfig = SyntheticCatalog.config()) -> PolicyContext {
    PolicyContext(snapshot: SyntheticCatalog().snapshot(), config: config, today: SyntheticCatalog.today,
                  spec: PlanSpecSummary(origin: .intro, canary: false, nominalDiscounts: [:], skippedIntroReplacements: [:]),
                  items: items, liveBinding: nil, liveBundleId: nil, otherApplyingPlanIds: [])
}

@Suite struct PolicyEngineTests {
    let cellA: CellKey = .regular(subscriptionId: "s", territory: "USA", planType: .upfront)
    let cellB: CellKey = .regular(subscriptionId: "s", territory: "CZE", planType: .upfront)

    @Test func evaluateRunsEveryRuleAndSortsVerdicts() {
        let engine = PolicyEngine(planRules: [
            FixedRule(id: "R7", verdicts: [Verdict(rule: "R7", severity: .warn, cell: cellA, message: "b")]),
            FixedRule(id: "A5", verdicts: [Verdict(rule: "A5", severity: .block(.plan), cell: nil, message: "a")]),
        ], invariants: [])
        #expect(engine.evaluate(emptyContext()).map(\.rule) == ["A5", "R7"])
    }

    @Test func confirmationLevels() {
        let config = SyntheticCatalog.config()
        let production = SyntheticCatalog.config(isProduction: true)
        let warn = Verdict(rule: "R9", severity: .warn, cell: nil, message: "w")
        let c2 = Verdict(rule: "R7", severity: .confirm(.c2), cell: cellA, message: "c2", riskClass: "R7 regular price decrease")
        #expect(PolicyEngine.confirmationLevel(for: [], config: config) == .c0)
        #expect(PolicyEngine.confirmationLevel(for: [warn], config: config) == .c0)
        #expect(PolicyEngine.confirmationLevel(for: [], config: production) == .c1)
        #expect(PolicyEngine.confirmationLevel(for: [warn, c2], config: config) == .c2)
        #expect(PolicyEngine.confirmationLevel(for: [c2], config: production) == .c2)
        #expect(PolicyEngine.confirmationLevel(for: [Verdict(rule: "A2", severity: .confirm(.c1), cell: nil, message: "p")], config: config) == .c1)
    }

    @Test func hashIgnoresOrderButNotContent() {
        let a = Verdict(rule: "R7", severity: .confirm(.c2), cell: cellA, message: "x", riskClass: "R7")
        let b = Verdict(rule: "S4", severity: .warn, cell: cellB, message: "y")
        #expect(PolicyEngine.hash([a, b]) == PolicyEngine.hash([b, a]))
        #expect(PolicyEngine.hash([a, b]) != PolicyEngine.hash([a]))
        #expect(PolicyEngine.hash([]).count == 64)
    }

    @Test func nominalDiscountsComeFromIntroTargets() {
        let mapping = ImportMapping(version: 1, source: .csv, firstDataRow: 2, countryColumn: "A", currencyColumn: "B", targets: [
            ImportTarget(column: "C", productAscId: "p1", kind: .regularPrice(planType: .upfront), nominalDiscount: Decimal(string: "0.5"), writes: true),
            ImportTarget(column: "D", productAscId: "p1", kind: .introPayUpFront(duration: .oneYear), nominalDiscount: Decimal(string: "0.2"), writes: true),
            ImportTarget(column: "E", productAscId: "p2", kind: .introPayAsYouGo(duration: .oneMonth, periods: 3), nominalDiscount: Decimal(string: "0.3"), writes: false),
        ])
        #expect(NominalDiscounts.from(mapping: mapping) == ["p1": Decimal(string: "0.2")!, "p2": Decimal(string: "0.3")!])
        #expect(NominalDiscounts.from(mapping: nil).isEmpty)
    }
}

@Suite struct RequestEstimatorTests {
    func post(_ seq: Int, _ sub: String, _ t: TerritoryCode) -> PlannedItem {
        let offer = NewIntroOffer(subscriptionId: sub, territory: t, planType: .upfront, mode: .freeTrial, duration: .oneWeek,
                                  numberOfPeriods: 1, startDate: nil, endDate: nil, pricePointId: nil)
        return PlannedItem(seq: seq, cell: .intro(subscriptionId: sub, territory: t, planType: .upfront), payload: .createIntro(offer),
                           before: .intro(current: nil, future: nil), target: .intro(current: nil, future: nil))
    }

    @Test func countsWritesAppReadPricePointBatchesAndReadPages() {
        let items = (0..<250).map { post($0 + 1, $0 < 210 ? "a" : "b", TerritoryCode("T\($0)")) }
        // 250 writes + 1 app read + 2 products + 2 × (2 pages for "a" + 1 page for "b")
        #expect(RequestEstimator.requests(items: items) == 250 + 1 + 2 + 2 * 3)
        #expect(RequestEstimator.requests(items: []) == 0)
    }

    @Test func minutesUseRemainingHourlyBudget() {
        #expect(RequestEstimator.minutes(requests: 535, rateLimit: RateLimitSnapshot.parse("user-hour-lim:3500;user-hour-rem:3500;", at: Date())) == 10)
        #expect(RequestEstimator.minutes(requests: 535, rateLimit: nil) == 2)
        #expect(RequestEstimator.minutes(requests: 10, rateLimit: RateLimitSnapshot.parse("user-hour-lim:3500;user-hour-rem:30;", at: Date())) == 10)
        #expect(RequestEstimator.minutes(requests: 0, rateLimit: nil) == 0)
    }
}

@Suite struct OfferMathTests {
    @Test func shapes() {
        #expect(OfferMath.isValidShape(mode: .payAsYouGo, duration: .oneYear, periods: 1, period: .oneYear))
        #expect(!OfferMath.isValidShape(mode: .payAsYouGo, duration: .oneYear, periods: 2, period: .oneYear))
        #expect(!OfferMath.isValidShape(mode: .payAsYouGo, duration: .oneMonth, periods: 1, period: .oneYear))
        #expect(OfferMath.isValidShape(mode: .payAsYouGo, duration: .oneMonth, periods: 12, period: .oneMonth))
        #expect(!OfferMath.isValidShape(mode: .payAsYouGo, duration: .oneMonth, periods: 13, period: .oneMonth))
        #expect(OfferMath.isValidShape(mode: .payUpFront, duration: .threeMonths, periods: 1, period: .oneYear))
        #expect(!OfferMath.isValidShape(mode: .payUpFront, duration: .oneWeek, periods: 1, period: .oneYear))
        #expect(!OfferMath.isValidShape(mode: .payUpFront, duration: .oneYear, periods: 2, period: .oneYear))
        #expect(OfferMath.isValidShape(mode: .freeTrial, duration: .threeDays, periods: 1, period: .oneYear))
        #expect(!OfferMath.isValidShape(mode: .freeTrial, duration: .oneWeek, periods: 2, period: .oneMonth))
    }

    @Test func multiplier() {
        #expect(OfferMath.regularMultiplier(mode: .payUpFront, duration: .oneYear, period: .oneYear) == 1)
        #expect(OfferMath.regularMultiplier(mode: .payUpFront, duration: .threeMonths, period: .oneMonth) == 3)
        #expect(OfferMath.regularMultiplier(mode: .payUpFront, duration: .threeMonths, period: .oneYear) == 1)
        #expect(OfferMath.regularMultiplier(mode: .payAsYouGo, duration: .oneMonth, period: .oneMonth) == 1)
    }
}

@Suite struct PlanProjectionTests {
    @Test func projectionUsesLastTargetPerCell() {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": SyntheticCatalog.d("29.99")])
        let snapshot = catalog.snapshot()
        let today = SyntheticCatalog.today
        let cell: CellKey = .regular(subscriptionId: "s", territory: "USA", planType: .upfront)
        let current = snapshot.currentRegular(subscriptionId: "s", territory: "USA", planType: .upfront, on: today)
        let newRow = RegularPriceRow(ascId: "", subscriptionId: "s", territory: "USA", planType: .upfront, rawPlanType: "UPFRONT",
                                     startDate: today.adding(days: 10), preserved: false, pricePointId: "x", customerPrice: SyntheticCatalog.d("24.99"))
        let item = PlannedItem(seq: 1, cell: cell,
                               payload: .createRegularPrice(NewRegularPrice(subscriptionId: "s", territory: "USA", planType: .upfront, pricePointId: "x",
                                                                            startDate: today.adding(days: 10), preserveCurrentPrice: false)),
                               before: .regular(current: current, scheduled: nil), target: .regular(current: current, scheduled: newRow))
        let projection = PlanProjection(snapshot: snapshot, items: [item], today: today)
        #expect(projection.regularPrice("s", "USA", .upfront, on: today) == SyntheticCatalog.d("29.99"))
        #expect(projection.regularPrice("s", "USA", .upfront, on: today.adding(days: 10)) == SyntheticCatalog.d("24.99"))
        let window = projection.regularPrices("s", "USA", .upfront, from: today, to: nil)
        #expect(window.map(\.price) == [SyntheticCatalog.d("29.99"), SyntheticCatalog.d("24.99")])
        #expect(projection.regularPrices("s", "USA", .upfront, from: today, to: today.adding(days: 5)).count == 1)
    }

    @Test func introWindowStartsTodayAndEndsExclusive() {
        let today = SyntheticCatalog.today
        let row = IntroOfferRow(ascId: "i", subscriptionId: "s", territory: "USA", planType: .upfront, rawPlanType: nil, mode: .payUpFront,
                                duration: .oneYear, numberOfPeriods: 1, startDate: CalendarDate(year: 2026, month: 1, day: 1),
                                endDate: today, pricePointId: nil, customerPrice: nil)
        #expect(IntroWindow(row: row, today: today) == nil)
        var open = row
        open.endDate = nil
        #expect(IntroWindow(row: open, today: today)?.from == today)
    }
}

@Suite struct InvariantRunnerTests {
    @Test func storesNewFindingsOnceAndAuditsThem() throws {
        let database = try WorkspaceDatabase.inMemory()
        let audit = AuditLog(database: database, actor: { "tester" }, now: { Date(timeIntervalSince1970: 0) })
        let catalog = CatalogStore(database: database)
        let cell: CellKey = .intro(subscriptionId: "s", territory: "USA", planType: .upfront)
        let rule = FixedRule(id: "I4", verdicts: [Verdict(rule: "I4", severity: .block(.cell), cell: cell, message: "The intro 31.99 USD is not cheaper than the regular price 29.99 USD")])
        let runner = InvariantRunner(engine: PolicyEngine(planRules: [], invariants: [rule]), catalog: catalog, database: database, audit: audit)
        let first = try runner.run(snapshot: SyntheticCatalog().snapshot(), today: SyntheticCatalog.today)
        #expect(first.count == 1)
        #expect(first[0].type == .invariant)
        #expect(first[0].rule == "I4")
        #expect(first[0].fingerprint == InvariantRunner.fingerprint(type: .invariant, rule: "I4", cell: cell, message: first[0].message))
        let second = try runner.run(snapshot: SyntheticCatalog().snapshot(), today: SyntheticCatalog.today)
        #expect(second.isEmpty)
        #expect(try catalog.findings(includeAcked: true).count == 1)
        let events = try audit.events(after: 0, limit: 10)
        #expect(events.map(\.type) == [.findingRaised])
        // K3 refs keys of findingRaised: syncId, finding, rule, cell (SyntheticCatalog snapshots have syncId 7).
        #expect(events[0].refs == ["syncId": "7", "finding": String(first[0].id), "rule": "I4", "cell": cell.storageKey])
    }
}
