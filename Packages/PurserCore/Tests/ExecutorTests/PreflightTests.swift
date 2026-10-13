import Foundation
import Testing
import Domain
import Store
import Catalog
import Policy
import Planner
@testable import Executor
import PurserTestSupport

private func day(_ s: String) -> CalendarDate { CalendarDate(iso: s)! }

private struct FixedRule: PlanRule {
    let id: RuleID
    let severity: Severity
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        [Verdict(rule: id, severity: severity, cell: context.items.first?.cell, message: "test rule \(id)",
                 riskClass: severity == .confirm(.c2) ? "R7 decrease" : nil)]
    }
}

private let czeRegular = CellKey.regular(subscriptionId: "sub-y", territory: "CZE", planType: .upfront)

private func preflight(_ h: ExecutorHarness, policy: PolicyEngine = PolicyEngine(planRules: [], invariants: [])) -> Preflight {
    Preflight(store: h.store, config: h.config, reader: h.reader, sync: h.sync, catalog: h.catalog, policy: policy, now: h.clock.nowFunction)
}

/// sub-y CZE gets a scheduled change on 2026-11-20 (price-sched-cze); the plan replaces it: DELETE -> POST.
private func replacePlan(_ h: ExecutorHarness) async throws -> (String, [PlannedItem]) {
    await h.fake.mutate { model in
        model.regularPrices.append(FakeRegularPrice(id: "price-sched-cze", subscriptionId: "sub-y", territory: "CZE", planType: .upfront,
                                                    sendsPlanType: true, startDate: CalendarDate(iso: "2026-11-20"), preserved: false,
                                                    pricePointId: "pp-sub-y-CZE-11"))
    }
    let snapshot = try await h.initialSync()
    let items = ItemFactory.chain(cell: czeRegular, payloads: [
        .deleteRegularPrice(ascId: "price-sched-cze"),
        .createRegularPrice(NewRegularPrice(subscriptionId: "sub-y", territory: "CZE", planType: .upfront, pricePointId: "pp-sub-y-CZE-12",
                                            startDate: day("2026-11-20"), preserveCurrentPrice: true)),
    ], firstSeq: 1, snapshot: snapshot, today: h.today)
    return (try h.insertPlan(items: items), items)
}

@Suite("Preflight")
struct PreflightTests {
    @Test func firstStartPassesWhenLiveEqualsBefore() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await replacePlan(h)
        let outcome = try await preflight(h).run(planId: planId, mode: .firstStart)
        #expect(outcome.staleCells.isEmpty)
        #expect(outcome.planBlockers.isEmpty)
        #expect(outcome.productStates == ["sub-y": .approved])
        #expect(!outcome.verdictHashChanged)
        #expect(outcome.level == .c0)
        #expect(outcome.liveApp.bundleId == "com.example.fruitjar")
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func firstStartMarksCellStaleOnAnyDifference() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await replacePlan(h)
        await h.fake.mutate { model in
            let index = model.regularPrices.firstIndex { $0.id == "price-sched-cze" }!
            model.regularPrices[index].pricePointId = "pp-sub-y-CZE-15"
        }
        let outcome = try await preflight(h).run(planId: planId, mode: .firstStart)
        #expect(outcome.staleCells == [czeRegular])
    }

    @Test func bindingIsCheckedAgainstConfigAndLiveApp() async throws {
        let h = try await ExecutorHarness.make()
        _ = try await h.initialSync()
        var foreign = PlanBinding(config: h.config)
        foreign.keyId = "OTHERKEY"
        let wrongKey = try h.insertPlan(items: [], binding: foreign)
        await #expect(throws: ExecutorError.bindingMismatch("config")) { _ = try await preflight(h).run(planId: wrongKey, mode: .firstStart) }
        let ok = try h.insertPlan(items: [])
        await h.fake.mutate { $0.app.bundleId = "com.example.other" }
        await #expect(throws: ExecutorError.bindingMismatch("live")) { _ = try await preflight(h).run(planId: ok, mode: .firstStart) }
    }

    @Test func anotherApplyingPlanBlocksA3() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await replacePlan(h)
        let other = try h.insertPlan(items: [], state: .applying)
        await #expect(throws: ExecutorError.anotherPlanApplying(other)) { _ = try await preflight(h).run(planId: planId, mode: .firstStart) }
    }

    @Test func productInReviewIsBlockedByA5AndStatesAreReported() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await replacePlan(h)
        await h.fake.mutate { model in
            let index = model.subscriptions.firstIndex { $0.id == "sub-y" }!
            model.subscriptions[index].state = .waitingForReview
        }
        let outcome = try await preflight(h).run(planId: planId, mode: .firstStart)
        #expect(outcome.productStates["sub-y"] == .waitingForReview)
        #expect(outcome.planBlockers.map(\.rule) == ["A5"])
    }

    @Test func freshPolicyChangesVerdictHashLevelAndCellBlocks() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await replacePlan(h)
        let policy = PolicyEngine(planRules: [FixedRule(id: "R7", severity: .confirm(.c2)), FixedRule(id: "S4", severity: .block(.cell))],
                                  invariants: [])
        let outcome = try await preflight(h, policy: policy).run(planId: planId, mode: .firstStart)
        #expect(outcome.verdictHashChanged)
        #expect(outcome.level == .c2)
        #expect(outcome.cellBlockers[czeRegular]?.map(\.rule) == ["S4"])
    }

    @Test func targetedResyncReadsOnlyAffectedProducts() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await replacePlan(h)
        let before = await h.fake.requests().count
        _ = try await preflight(h).run(planId: planId, mode: .firstStart)
        let after = await h.fake.requests().dropFirst(before)
        #expect(after.contains { $0.path == "/v1/subscriptions/sub-y/prices" })
        #expect(!after.contains { $0.path == "/v1/subscriptions/sub-m/prices" })
    }

    @Test func resumeResolvesInFlightToDoneAndChecksNextItem() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await replacePlan(h)
        try h.setItemState(planId: planId, seq: 1, .inFlight)
        try await h.writer.deleteRegularPrice(ascId: "price-sched-cze")
        let outcome = try await preflight(h).run(planId: planId, mode: .resume)
        #expect(outcome.itemChanges.map(\.seq) == [1])
        #expect(outcome.itemChanges.first?.to == .done)
    }

    @Test func resumeReturnsUnappliedInFlightToPending() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await replacePlan(h)
        try h.setItemState(planId: planId, seq: 1, .inFlight)
        let outcome = try await preflight(h).run(planId: planId, mode: .resume)
        #expect(outcome.itemChanges == [ItemChange(seq: 1, to: .pending, ascId: nil, note: "preflight 2b: not applied, back to Pending")])
    }

    @Test func resumeMarksDivergedCellsStale() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await replacePlan(h)
        try h.setItemState(planId: planId, seq: 1, .done)
        await h.fake.mutate { model in
            let index = model.regularPrices.firstIndex { $0.id == "price-sched-cze" }!
            model.regularPrices[index].pricePointId = "pp-sub-y-CZE-15"
        }
        let outcome = try await preflight(h).run(planId: planId, mode: .resume)
        #expect(outcome.itemChanges.map(\.seq) == [2])
        #expect(outcome.itemChanges.first?.to == .stale)
    }

    @Test func summarizerReadsStoredSpec() throws {
        let json = try JSONCoding.string(PlanSpec.withdraw(WithdrawPlanSpec(planId: "p", itemSeqs: [1])))
        let config = WorkspaceConfig(id: UUID(), name: "FruitJar", colorHex: "#000000", isProduction: false, appId: "1", bundleId: "b",
                                     keyKind: .individual, keyId: "K", issuerId: nil, importMapping: nil, googleClientId: nil,
                                     slackWebhookEnabled: false, nightlySyncHourUTC: 3)
        let summary = try PlanSpecSummarizer.summary(specJSON: json, config: config)
        #expect(summary.origin == .withdraw)
        #expect(!summary.canary)
        #expect(summary.effectiveLiveIntroCanaryProducts.isEmpty)
        let unlocked = try PlanSpecSummarizer.summary(specJSON: json, config: config, unlockedCanaries: ["sub-1"])
        #expect(unlocked.effectiveLiveIntroCanaryProducts == ["sub-1"])
        #expect(throws: ExecutorError.corruptPlan("spec_json is not a PlanSpec")) { try PlanSpecSummarizer.summary(specJSON: "{}", config: config) }
    }
}
