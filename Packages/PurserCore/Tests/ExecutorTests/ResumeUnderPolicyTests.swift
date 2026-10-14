import Foundation
import Testing
import Domain
import Catalog
import Policy
import Planner
import Executor
import PurserTestSupport

/// A crash inside a chain, then recover() and one resume, all under the real policy, for the plan kinds besides the regular
/// decrease (RegularChangeScenarioTests). The resume preflight re-runs the policy over the items still to be written, so a
/// rule that reads the whole plan or the base state must still pass once part of a chain is in ASC (I8 and A4 did not).
/// Each test crashes once per chain boundary, after the commit and before it (the write landed, the item is in flight).
@Suite("Resume under the real policy")
struct ResumeUnderPolicyTests {
    func save(_ h: ExecutorHarness, _ spec: PlanSpec) async throws -> (planId: String, draft: PlanDraft) {
        let snapshot = try await h.initialSync()
        let draft = try Planner(policy: PolicyEngine()).plan(spec, context: PlanningContext(snapshot: snapshot, config: h.config, today: h.today))
        #expect(!draft.verdicts.contains { $0.severity == .block(.plan) || $0.severity == .block(.cell) }, "plan blocks: \(draft.verdicts)")
        let planId = try PlanPersistence(store: h.store, audit: h.audit, appBuild: "test")
            .saveDraft(draft, binding: PlanBinding(config: h.config), reason: "Resume under policy test", replanOf: nil)
        return (planId, draft)
    }

    func crash(_ seq: Int, beforeCommit: Bool) -> ExecutorStep {
        beforeCommit ? .afterResponse(seq: seq) : .afterItemCommitted(seq: seq)
    }

    /// Nothing Stale or Skipped, no duplicate rows, and every cell of the draft holds the target of its last item.
    func expectFinished(_ h: ExecutorHarness, planId: String, draft: PlanDraft, _ context: String) async throws {
        let stored = try h.store.items(planId: planId)
        let unfinished = stored.filter { ![.done, .effective].contains($0.state) }.map { "\($0.item.seq) \($0.item.op) \($0.state)" }
        #expect(unfinished.isEmpty, "\(context): \(unfinished)")
        #expect(await h.fake.duplicates().isEmpty, "\(context)")
        let snapshot = try await h.initialSync()
        for (cell, chain) in Dictionary(grouping: draft.items, by: \.cell) {
            let last = try #require(chain.max { $0.seq < $1.seq })
            #expect(Reconciler.matches(live: snapshot.cellState(cell, on: h.today), expected: last.target, today: h.today),
                    "\(context): \(cell.storageKey) is not at its target")
        }
    }

    /// Increase with preserveCurrentPrice: POST regular -> DELETE intro -> POST intro in every territory.
    @Test(arguments: [false, true])
    func increaseResumesAfterCrashInsideTheChain(beforeCommit: Bool) async throws {
        let regular = CellKey.regular(subscriptionId: "sub-n", territory: "CZE", planType: .upfront)
        let intro = CellKey.intro(subscriptionId: "sub-n", territory: "CZE", planType: .upfront)
        for (cell, op) in [(regular, ItemOp.post), (intro, .delete)] {
            let h = try await ExecutorHarness.make(model: RegularChangeScenarioTests.model())
            let (planId, draft) = try await save(h, RegularChangeScenarioTests.spec(newPrice: "34.99", preserve: true, start: h.today.adding(days: 9)))
            let item = try #require(draft.items.first { $0.cell == cell && $0.op == op })
            let step = crash(item.seq, beforeCommit: beforeCommit)
            #expect(try await h.crashAndResume(planId: planId, at: step) == .scheduled, "crash at \(step)")
            let writes = await RegularChangeScenarioTests.writes(h)
            for territory in RegularChangeScenarioTests.territories {
                #expect(writes.filter { $0.territory == territory.rawValue }.count == 3, "crash at \(step), \(territory): \(writes)")
            }
            try await expectFinished(h, planId: planId, draft: draft, "crash at \(step)")
        }
    }

    /// CANARY on an approved subscription: PATCH_END of the live intro -> POST of its replacement (I7).
    @Test(arguments: [false, true])
    func liveIntroCanaryResumesAfterCrashBehindPatchEnd(beforeCommit: Bool) async throws {
        var model = FakeSeed.fruitJar()
        model.intros.append(FakeIntro(id: "intro-live-sub-y-CZE", subscriptionId: "sub-y", territory: "CZE", planType: .upfront,
                                      mode: .payUpFront, duration: .oneYear, numberOfPeriods: 1, startDate: FakeSeed.seedStart, endDate: nil,
                                      pricePointId: "pp-sub-y-CZE-5", createdOn: FakeSeed.seedStart))
        let h = try await ExecutorHarness.make(model: model)
        let (planId, draft) = try await save(h, .intro(IntroPlanSpec(
            subscriptionIds: ["sub-y"], mode: .freeTrial, duration: .oneWeek, numberOfPeriods: 1, pricing: .freeTrial,
            startDate: h.today.adding(days: 9), endDate: nil, nominalDiscount: nil, filter: PlanFilter(territories: ["CZE"]), canary: true)))
        #expect(draft.items.map(\.op) == [.patchEnd, .post])
        let step = crash(1, beforeCommit: beforeCommit)
        #expect(try await h.crashAndResume(planId: planId, at: step) == .scheduled, "crash at \(step)")
        #expect(await h.fake.writeRequests().filter(\.applied).count == 2)
        try await expectFinished(h, planId: planId, draft: draft, "crash at \(step)")
    }

    /// A new promo: once its POST landed, ASC already knows the offer code (O1) and the cell is no longer empty (A4).
    @Test(arguments: [false, true])
    func promoCreateResumesAfterCrashBehindItsPost(beforeCommit: Bool) async throws {
        let h = try await ExecutorHarness.make(model: RegularChangeScenarioTests.model())
        let (planId, draft) = try await save(h, .promo(PromoPlanSpec(action: .create(
            subscriptionId: "sub-n", offerCode: "jar_spring", name: "Spring", mode: .payAsYouGo, duration: .oneYear, numberOfPeriods: 1,
            pricing: .percentOfRegular(Decimal(string: "0.5")!)))))
        #expect(draft.items.map(\.op) == [.post])
        let step = crash(1, beforeCommit: beforeCommit)
        #expect(try await h.crashAndResume(planId: planId, at: step) == .effective, "crash at \(step)")
        #expect(await h.fake.writeRequests().filter(\.applied).count == 1)
        try await expectFinished(h, planId: planId, draft: draft, "crash at \(step)")
    }
}
