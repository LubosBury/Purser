import Foundation
import Testing
import Domain
import Store
import Audit
import Catalog
import Policy
@testable import Executor
import PurserTestSupport

private struct SimulatedCrash: Error {}

private func day(_ s: String) -> CalendarDate { CalendarDate(iso: s)! }

/// Crashes the first executor when `shouldCrash` says so, then restarts with recover() + resume().
private func crashAndResume(_ h: ExecutorHarness, planId: String, policy: PolicyEngine = PolicyEngine(planRules: [], invariants: []),
                            shouldCrash: @escaping @Sendable (Int, ExecutorStep) -> Bool) async throws -> PlanState {
    let first = h.makeExecutor(policy: policy)
    let counter = Locked(0)
    await first.setStepHook { step in
        var index = 0
        counter.update { $0 += 1; index = $0 - 1 }
        if shouldCrash(index, step) { throw SimulatedCrash() }
    }
    do {
        _ = try await first.apply(planId: planId, confirm: Confirm.accept)
        Issue.record("the simulated crash did not happen")
    } catch is SimulatedCrash {
    }
    h.clock.advance(by: AppleConstants.heartbeatSeconds * 4)
    let second = h.makeExecutor(policy: policy)
    #expect(try await second.recover(afterWake: false) == [planId])
    return try await second.resume(planId: planId, confirm: Confirm.accept)
}

/// Invariants from spec §9: final state = target, no duplicate rows, every HTTP_SENT followed by a read.
private func assertInvariants(_ h: ExecutorHarness, planId: String, items: [PlannedItem], context: String) async throws {
    let stored = try h.store.items(planId: planId)
    #expect(!stored.contains { $0.state == .inFlight || $0.state == .pending }, "\(context): unfinished items")
    let duplicates = await h.fake.duplicates()
    #expect(duplicates.isEmpty, "\(context): duplicates \(duplicates)")
    _ = try await h.sync.sync(trigger: .manual, scope: .all)
    let snapshot = try h.snapshot()
    for (cell, chain) in Dictionary(grouping: items, by: \.cell) {
        let last = chain.max { $0.seq < $1.seq }!
        #expect(Reconciler.matches(live: snapshot.cellState(cell, on: h.today), expected: last.target, today: h.today),
                "\(context): cell \(cell) does not match its target")
    }
    let events = try h.audit.events(after: 0, limit: 1_000_000)
    let productOfSeq = Dictionary(uniqueKeysWithValues: items.map { (String($0.seq), $0.cell.productAscId) })
    for sent in events where sent.type == .httpSent {
        let product = productOfSeq[sent.refs["seq"] ?? ""] ?? "?"
        #expect(events.contains { $0.type == .verify && $0.seq > sent.seq && $0.refs["product"] == product },
                "\(context): httpSent #\(sent.seq) for \(product) has no later read")
    }
}

@Suite("Crash and resume")
struct CrashResumeTests {
    @Test func undisturbedTwelveItemRunHas54Steps() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, items) = try await Scenarios.plan(h, cells: Scenarios.twelveItems)
        #expect(items.count == 12)
        let executor = h.makeExecutor()
        let steps = Locked<[ExecutorStep]>([])
        await executor.setStepHook { step in steps.update { $0.append(step) } }
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(steps.value.count == 54)
        try await assertInvariants(h, planId: planId, items: items, context: "undisturbed")
    }

    @Test func crashAtEveryStepOfTheTwelveItemPlanResumesToTarget() async throws {
        for k in 0..<54 {
            let h = try await ExecutorHarness.make()
            let (planId, items) = try await Scenarios.plan(h, cells: Scenarios.twelveItems)
            let final = try await crashAndResume(h, planId: planId) { index, _ in index == k }
            #expect(final == .scheduled, "step \(k)")
            try await assertInvariants(h, planId: planId, items: items, context: "crash at step \(k)")
        }
    }

    @Test func crashAfterItem212Of525ResumesWithoutResending() async throws {
        let h = try await ExecutorHarness.make(model: FakeSeed.wide(subscriptionCount: 3, territoryCount: 175))
        let codes = (1...175).map { TerritoryCode(String(format: "T%03d", $0)) }
        let cells = (1...3).flatMap { sub in codes.map { Scenarios.newIntro(sub: "sub-w\(sub)", territory: $0, start: "2026-11-01") } }
        let (planId, items) = try await Scenarios.plan(h, cells: cells)
        #expect(items.count == 525)
        let final = try await crashAndResume(h, planId: planId) { _, step in step == .afterItemCommitted(seq: 212) }
        #expect(final == .scheduled)
        #expect(await h.fake.model.intros.count == 525)
        #expect(try h.audit.events(after: 0, limit: 1_000_000).filter { $0.type == .httpSent }.count == 525)
        try await assertInvariants(h, planId: planId, items: items, context: "212/525")
    }

    @Test func crashBetweenDeleteAndPostResumesThePost() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, items) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let final = try await crashAndResume(h, planId: planId) { _, step in step == .afterItemCommitted(seq: 1) }
        #expect(final == .scheduled)
        #expect(try h.store.items(planId: planId).sorted { $0.item.seq < $1.item.seq }.map(\.state) == [.effective, .done])
        #expect(await h.fake.writeRequests().count == 2)
        try await assertInvariants(h, planId: planId, items: items, context: "DELETE -> POST")
    }

    @Test func crashAfterDeleteResponseBeforeCommitIsReconciled() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, items) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let final = try await crashAndResume(h, planId: planId) { _, step in step == .afterResponse(seq: 1) }
        #expect(final == .scheduled)
        #expect(await h.fake.writeRequests().count == 2)
        try await assertInvariants(h, planId: planId, items: items, context: "DELETE response lost")
    }

    @Test func crashBetweenPatchEndAndPostResumesThePost() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, items) = try await Scenarios.plan(h, cells: [Scenarios.endLiveIntroThenPost(territory: "DEU")])
        let final = try await crashAndResume(h, planId: planId) { _, step in step == .afterItemCommitted(seq: 1) }
        #expect(final == .scheduled)
        let model = await h.fake.model
        #expect(model.intros.first { $0.id == "intro-live-sub-y-DEU" }?.endDate == day("2026-11-01"))
        #expect(model.intros.contains { $0.territory == "DEU" && $0.startDate == day("2026-11-01") && $0.duration == .oneMonth })
        #expect(await h.fake.writeRequests().count == 2)
        try await assertInvariants(h, planId: planId, items: items, context: "PATCH_END -> POST")
    }

    /// The write reached ASC but the crash left the item InFlight: the live state is its target, not its before, and
    /// preflight 2b resolves it to Done. A4 must not block the first resume over it (the default policy, not the empty one).
    @Test func crashAfterAcceptedWriteResumesOnFirstTryUnderDefaultPolicy() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, items) = try await Scenarios.plan(h, cells: [Scenarios.newIntro(sub: "sub-m", territory: "USA", start: "2026-11-01")])
        let final = try await crashAndResume(h, planId: planId, policy: PolicyEngine()) { _, step in step == .afterResponse(seq: 1) }
        #expect(final == .scheduled)
        #expect(await h.fake.writeRequests().count == 1)
        try await assertInvariants(h, planId: planId, items: items, context: "POST accepted, InFlight")
    }

    @Test func crashAfterAcceptedDeleteResumesThePostUnderDefaultPolicy() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, items) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let final = try await crashAndResume(h, planId: planId, policy: PolicyEngine()) { _, step in step == .afterResponse(seq: 1) }
        #expect(final == .scheduled)
        #expect(await h.fake.writeRequests().count == 2)
        try await assertInvariants(h, planId: planId, items: items, context: "DELETE accepted, InFlight")
    }
}
