import Foundation
import Testing
import Domain
import Store
import Planner
@testable import Executor
import PurserTestSupport

@Suite("Drill plan factory")
struct DrillPlanFactoryTests {
    @Test func endThenPostChainIsAppliedLikeAnyPlan() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.mutate { model in
            model.intros.append(FakeIntro(id: "intro-live-n", subscriptionId: "sub-n", territory: "USA", planType: .upfront, mode: .freeTrial,
                                          duration: .oneWeek, numberOfPeriods: 1, startDate: CalendarDate(iso: "2026-10-01"), endDate: nil,
                                          pricePointId: nil, createdOn: CalendarDate(iso: "2026-10-01")!))
        }
        let snapshot = try await h.initialSync()
        let day = h.today.adding(days: 3)
        let items = DrillPlanFactory.endThenPost(snapshot: snapshot, subscriptionId: "sub-n", territories: ["USA", "CZE"],
                                                 day: day, newDuration: .twoWeeks, today: h.today)
        #expect(items.map(\.op) == [.patchEnd, .post])
        #expect(items[1].dependsOn == [1])
        let draft = try DrillPlanFactory.draft(items: items, subscriptionId: "sub-n", baseSyncId: snapshot.syncId)
        let planId = try PlanPersistence(store: h.store, audit: h.audit, appBuild: "test").saveDraft(draft, binding: PlanBinding(config: h.config),
                                                                                                    reason: nil, replanOf: nil)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        let model = await h.fake.model
        #expect(model.intros.first { $0.id == "intro-live-n" }?.endDate == day)
        #expect(model.intros.contains { $0.territory == "USA" && $0.startDate == day && $0.duration == .twoWeeks })
        #expect(await h.fake.duplicates().isEmpty)
    }
}
