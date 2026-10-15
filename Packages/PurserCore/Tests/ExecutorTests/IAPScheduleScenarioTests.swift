import Foundation
import Testing
import Domain
import Store
import Catalog
import Policy
import Planner
import Executor
import PurserTestSupport

/// IAP schedule plans through the real Planner, Executor, LiveASCClient (WriteBodies, AppGuard) and FakeASC (M2).
/// FruitJar's iap-life has base USA with one manual price pp-iap-life-USA-29 (29.99); IAP points cost 0.99 + i.
@Suite("IAP schedule end to end over FakeASC")
struct IAPScheduleScenarioTests {
    static func spec(_ prices: [(TerritoryCode, String)]) -> PlanSpec {
        .iap(IAPPlanSpec(iapId: "iap-life", baseTerritory: "USA",
                         prices: prices.map { TerritoryAmount(territory: $0.0, amount: Decimal(string: $0.1)!) }, startDate: nil))
    }

    func draft(_ h: ExecutorHarness, _ spec: PlanSpec) async throws -> PlanDraft {
        let snapshot = try await h.initialSync()
        return try Planner(policy: PolicyEngine()).plan(spec, context: PlanningContext(snapshot: snapshot, config: h.config, today: h.today))
    }

    func apply(_ h: ExecutorHarness, _ draft: PlanDraft,
               confirm: @escaping @Sendable (ConfirmationRequest) async -> ConfirmationResponse = Confirm.accept)
        async throws -> (planId: String, state: PlanState) {
        let planId = try PlanPersistence(store: h.store, audit: h.audit, appBuild: "test")
            .saveDraft(draft, binding: PlanBinding(config: h.config), reason: "IAP scenario test", replanOf: nil)
        return (planId, try await h.makeExecutor(policy: PolicyEngine()).apply(planId: planId, confirm: confirm))
    }

    @Test(.enabled(if: AppleConstants.iapScheduleReplaceConfirmed))
    func scheduleReplaceIsEffectiveAfterVerify() async throws {
        let h = try await ExecutorHarness.make()
        let draft = try await draft(h, Self.spec([("USA", "24.99"), ("CZE", "19.99")]))
        #expect(draft.items.map(\.op) == [.scheduleReplace])
        let result = try await apply(h, draft)
        #expect(result.state == .effective)
        #expect(await h.fake.writeRequests().map { "\($0.method) \($0.path)" } == ["POST /v1/inAppPurchasePriceSchedules"])
        let schedule = try #require(await h.fake.model.iapSchedules.first { $0.iapId == "iap-life" })
        #expect(Set(schedule.manualPrices.map(\.territory)) == ["USA", "CZE"])
        #expect(try h.store.items(planId: result.planId).allSatisfy { $0.state == .effective })
    }

    @Test(.enabled(if: AppleConstants.iapScheduleReplaceConfirmed))
    func echoedStartDateStillVerifies() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setIAPNullStartEchoesCreationDay(true)
        let result = try await apply(h, try await draft(h, Self.spec([("USA", "24.99"), ("CZE", "19.99")])))
        #expect(result.state == .effective)
        #expect(try h.store.items(planId: result.planId).allSatisfy { $0.state == .effective })
    }

    @Test(.enabled(if: AppleConstants.iapScheduleReplaceConfirmed))
    func decreaseOverThirtyPercentNeedsC2WithL3Class() async throws {
        let h = try await ExecutorHarness.make()
        let draft = try await draft(h, Self.spec([("USA", "14.99")]))
        #expect(draft.confirmationLevel == .c2)
        let recorded = Locked<[ConfirmationRequest]>([])
        let result = try await apply(h, draft) { request in
            recorded.update { $0.append(request) }
            return await Confirm.accept(request)
        }
        #expect(result.state == .effective)
        let request = try #require(recorded.value.first)
        #expect(request.level == .c2)
        #expect(request.riskClasses.keys.contains { $0.contains("L3") })
    }

    @Test(.enabled(if: !AppleConstants.iapScheduleReplaceConfirmed))
    func scheduleReplaceIsBlockedBeforeSpikeS10() async throws {
        let h = try await ExecutorHarness.make()
        let draft = try await draft(h, Self.spec([("USA", "24.99")]))
        #expect(draft.verdicts.contains { $0.rule == "S10" && $0.severity == .block(.plan) })
    }

    /// FruitJar's iap-life with a schedule that keeps base USA and has no manual price (exception S10a).
    static func dropManualPrices(_ h: ExecutorHarness) async {
        await h.fake.mutate { model in
            for i in model.iapSchedules.indices where model.iapSchedules[i].iapId == "iap-life" { model.iapSchedules[i].manualPrices = [] }
        }
    }

    @Test(.enabled(if: !AppleConstants.iapScheduleReplaceConfirmed))
    func scheduleReplaceOverAManualPriceHasNoS10a() async throws {
        let h = try await ExecutorHarness.make()
        let draft = try await draft(h, Self.spec([("USA", "24.99")]))
        #expect(draft.verdicts.contains { $0.rule == "S10" && $0.severity == .block(.plan) })
        #expect(!draft.verdicts.contains { $0.rule == "S10a" })
    }

    @Test(.enabled(if: !AppleConstants.iapScheduleReplaceConfirmed), arguments: [false, true])
    func iapWithoutManualPricesPassesWithS10a(removeSchedule: Bool) async throws {
        let h = try await ExecutorHarness.make()
        if removeSchedule {
            await h.fake.mutate { $0.iapSchedules.removeAll { $0.iapId == "iap-life" } }
        } else {
            await Self.dropManualPrices(h)
        }
        let draft = try await draft(h, Self.spec([("USA", "24.99"), ("CZE", "19.99")]))
        #expect(!draft.verdicts.contains { if case .block = $0.severity { return true } else { return false } })
        #expect(draft.verdicts.contains { $0.rule == "S10a" && $0.severity == .warn })

        let result = try await apply(h, draft)
        #expect(result.state == .effective)
        #expect(await h.fake.writeRequests().map { "\($0.method) \($0.path)" } == ["POST /v1/inAppPurchasePriceSchedules"])
        let confirmation = try #require(try h.audit.events(after: 0, limit: 100_000).last { $0.type == .confirmation })
        #expect(confirmation.payloadJSON.contains("\"exceptions\":[\"S10a\"]"))
    }

    @Test(.enabled(if: !AppleConstants.iapScheduleReplaceConfirmed))
    func manualPriceAddedBeforeApplyStopsItInDraft() async throws {
        let h = try await ExecutorHarness.make()
        await Self.dropManualPrices(h)
        let draft = try await draft(h, Self.spec([("USA", "24.99")]))
        #expect(draft.verdicts.contains { $0.rule == "S10a" })
        await h.fake.mutate { model in
            for i in model.iapSchedules.indices where model.iapSchedules[i].iapId == "iap-life" {
                model.iapSchedules[i].manualPrices = [FakeIAPManualPrice(id: "iapprice-new", territory: "USA",
                                                                         pricePointId: "pp-iap-life-USA-29", startDate: nil, endDate: nil)]
            }
        }

        let result = try await apply(h, draft)
        #expect(result.state == .draft)
        #expect(await h.fake.writeRequests().isEmpty)
        let plan = try #require(try h.store.plan(id: result.planId))
        #expect(plan.verdicts.contains { $0.rule == "S10" && $0.severity == .block(.plan) })
        #expect(!plan.verdicts.contains { $0.rule == "S10a" })
        #expect(try h.store.items(planId: result.planId).allSatisfy { $0.state == .pending })
    }
}
