import Foundation
import Testing
import Domain
import Store
import Catalog
import Planner
import Policy
@testable import Executor
import PurserTestSupport

@Suite("Ready for review after a new version (L3)")
struct NewVersionReadyForReviewTests {
    @Test func aPlanThatCreatedAVersionEndsReadyForReviewUntilItIsSubmitted() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        #expect(try await h.makeExecutor().apply(planId: planned.planId, confirm: Confirm.accept) == .effective)
        let plan = try #require(try h.store.plan(id: planned.planId))
        let items = try h.store.items(planId: planned.planId)
        #expect(ReadyForReview.owners(plan: plan, items: items, metadata: try h.snapshot().metadata) == [NewVersionScenario.owner])
        // The owner submits it in App Store Connect: after the next sync the prompt is gone.
        await h.fake.mutate { model in
            if let index = model.versions.firstIndex(where: { $0.owner == NewVersionScenario.owner && $0.state == .prepareForSubmission }) {
                model.versions[index].state = .waitingForReview
            }
        }
        let submitted = try await h.initialSync()
        #expect(ReadyForReview.owners(plan: plan, items: items, metadata: submitted.metadata).isEmpty)
    }

    @Test func aVersionWhoseTextFailedIsIncompleteNotReady() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        // de-DE is the only POST into the new version; App Store Connect refuses it.
        await h.fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Synthetic refusal"), times: 1, matching: .pathPrefix("/v2/subscriptionLocalizations"))
        #expect(try await h.makeExecutor().apply(planId: planned.planId, confirm: Confirm.accept) == .partiallyApplied)
        let plan = try #require(try h.store.plan(id: planned.planId))
        let items = try h.store.items(planId: planned.planId)
        let german = try #require(NewVersionScenario.seq(planned, locale: "de-DE"))
        #expect(items.first { $0.item.seq == german }?.state == .failed)
        let status = ReadyForReview.status(plan: plan, items: items, metadata: try h.snapshot().metadata)
        #expect(status.ready.isEmpty)
        #expect(status.incomplete == [NewVersionScenario.owner])

        // replan_rest writes de-DE into the same version; after its verify sync the original (now Closed) plan is ready.
        let rest = try await h.makeExecutor().replanRest(planId: planned.planId, planner: Planner(policy: PolicyEngine()), freshTable: nil)
        #expect(try await h.makeExecutor().apply(planId: rest, confirm: Confirm.accept) == .effective)
        let closed = try #require(try h.store.plan(id: planned.planId))
        #expect(closed.state == .closed)
        #expect(ReadyForReview.status(plan: closed, items: items, metadata: try h.snapshot().metadata)
                    == ReadyForReview.Status(ready: [NewVersionScenario.owner], incomplete: []))
        #expect(await h.fake.writeRequests().filter { $0.path == "/v1/subscriptionVersions" }.count == 1)
    }
}
