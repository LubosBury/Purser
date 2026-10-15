import Foundation
import Testing
import Domain
import Store
import Catalog
import Policy
import Planner
import Executor
import PurserTestSupport

/// The exit criterion of cloning over FakeASC: clones of SpikeYearlyA and PurserSpikeLifetime, the sync after them, the
/// drafts of CloneDrafts planned at once and applied in their order, every plan Effective and the clones on the price
/// points of the same tier as their sources (FakeSeed points cost 0.99 + i and end with "-<territory>-<i>").
@Suite("Clone end to end over FakeASC")
struct CloneEndToEndTests {
    @Test func aCloneWithAllItsDraftsAppliedEndsEffectiveOnTheSourceTiers() async throws {
        let h = try await ExecutorHarness.make(model: FakeSeed.cloneSource())
        let before = try await h.initialSync()
        let request = CloneRequest(items: [
            CloneItem(source: .subscription("sub-spike-a"), productId: "SpikeYearlyA_AB3", name: "SpikeYearlyA_AB3"),
            CloneItem(source: .iap("iap-spike"), productId: "PurserSpikeLifetime_AB3", name: "PurserSpikeLifetime_AB3"),
        ], group: .sourceGroup, level: .sameAsSource, copy: CloneCopy(), offerCodeSuffix: "_AB3")
        let report = try await h.makeProductCreator().clone(request, snapshot: before)
        #expect(report.steps.allSatisfy { if case .created = $0.outcome { return true } else { return false } })
        let yearly = try #require(report.created["sub-spike-a"])
        let lifetime = try #require(report.created["iap-spike"])

        let after = try await h.initialSync()
        #expect(CloneDrafts.notCopied(created: report.created, copy: request.copy, offerCodeSuffix: request.offerCodeSuffix,
                                      snapshot: after, today: h.today).isEmpty)
        let drafts = CloneDrafts.specs(created: report.created, copy: request.copy, offerCodeSuffix: request.offerCodeSuffix,
                                       snapshot: after, today: h.today)
        #expect(drafts.count == 4)       // regular prices, the free trial everywhere, the promo, the IAP prices
        let planner = Planner(policy: PolicyEngine())
        let persistence = PlanPersistence(store: h.store, audit: h.audit, appBuild: "test")
        var planIds: [String] = []
        for draft in drafts {
            let planned = try planner.plan(draft.spec, context: PlanningContext(snapshot: after, config: h.config, today: h.today))
            #expect(!planned.verdicts.contains { if case .block = $0.severity { return true } else { return false } }, "\(draft.title)")
            planIds.append(try persistence.saveDraft(planned, binding: PlanBinding(config: h.config), reason: draft.title, replanOf: nil))
        }
        for (planId, draft) in zip(planIds, drafts) {
            let state = try await h.makeExecutor(policy: PolicyEngine()).apply(planId: planId, confirm: Confirm.accept)
            #expect(state == .effective, "\(draft.title)")
        }

        let model = await h.fake.model
        for territory in model.territories.keys {
            #expect(model.regularPrices.first { $0.subscriptionId == "sub-spike-a" && $0.territory == territory }?.pricePointId
                    == "pp-sub-spike-a-\(territory)-9")
            #expect(model.regularPrices.first { $0.subscriptionId == yearly && $0.territory == territory }?.pricePointId
                    == "pp-\(yearly)-\(territory)-9")
        }
        #expect(Set(model.intros.filter { $0.subscriptionId == yearly }.map(\.territory)) == Set(model.territories.keys))
        let promo = try #require(model.promos.first { $0.subscriptionId == yearly })
        #expect(promo.offerCode == "spike_winback_AB3")
        #expect(promo.prices.allSatisfy { $0.pricePointId == "pp-\(yearly)-\($0.territory)-4" })
        #expect(model.iapSchedules.first { $0.iapId == lifetime }?.manualPrices.map(\.pricePointId) == ["pp-\(lifetime)-USA-29"])

        // Everything the drafts carry is now on the clones: preparing them again finds nothing left to draft or to say.
        let finished = try await h.initialSync()
        #expect(CloneDrafts.specs(created: report.created, copy: request.copy, offerCodeSuffix: request.offerCodeSuffix,
                                  snapshot: finished, today: h.today).isEmpty)
        #expect(CloneDrafts.notCopied(created: report.created, copy: request.copy, offerCodeSuffix: request.offerCodeSuffix,
                                      snapshot: finished, today: h.today).isEmpty)
    }
}
