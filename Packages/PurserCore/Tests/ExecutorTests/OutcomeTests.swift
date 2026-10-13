import Foundation
import Testing
import Domain
import Store
import ASCClient
import Catalog
import Policy
import Planner
@testable import Executor
import PurserTestSupport

private func day(_ s: String) -> CalendarDate { CalendarDate(iso: s)! }
private let gbr = CellKey.regular(subscriptionId: "sub-y", territory: "GBR", planType: .upfront)
private let jpn = CellKey.regular(subscriptionId: "sub-y", territory: "JPN", planType: .upfront)

private func row(_ id: String, start: String?) -> RegularPriceRow {
    RegularPriceRow(ascId: id, subscriptionId: "sub-y", territory: "GBR", planType: .upfront, rawPlanType: "UPFRONT",
                    startDate: start.map(day), preserved: false, pricePointId: "pp-\(id)", customerPrice: 1)
}

private func stored(_ payload: WritePayload, _ state: ItemState, ascId: String? = nil, verified: Bool = false) -> StoredItem {
    StoredItem(planId: "p", item: PlannedItem(seq: 1, cell: gbr, payload: payload, before: .regular(current: nil, scheduled: nil),
                                              target: .regular(current: nil, scheduled: nil)),
               state: state, attempts: 1, ascId: ascId, errorJSON: nil, verifiedAt: verified ? Date() : nil, effectiveAt: nil, supersededBy: nil)
}

private func post(_ start: String) -> WritePayload {
    .createRegularPrice(NewRegularPrice(subscriptionId: "sub-y", territory: "GBR", planType: .upfront, pricePointId: "pp-x",
                                        startDate: day(start), preserveCurrentPrice: true))
}

private func snapshotWith(_ rows: [RegularPriceRow]) -> CatalogSnapshot {
    CatalogSnapshot(syncId: 1, takenAt: Date(), subscriptions: [:], iaps: [:], territories: ["GBR": "GBP"], regularRows: rows,
                    introRows: [], promoOffers: [], iapSchedules: [:], pricePoints: PricePointIndex([]), offerCodesEverSeen: [])
}

private func setSpec(_ h: ExecutorHarness, _ planId: String, _ spec: PlanSpec) throws {
    let json = try JSONCoding.string(spec)
    try h.updatePlan(planId) { $0.specJSON = json }
}

@Suite("Plan outcomes")
struct OutcomeTests {
    @Test func afterSyncRules() {
        let effective = stored(.deletePromo(ascId: "o"), .effective)
        let done = stored(post("2026-11-15"), .done)
        let superseded = stored(post("2026-11-15"), .superseded)
        let withdrawn = stored(post("2026-11-15"), .withdrawn)
        #expect(OutcomeCalculator.afterSync([superseded])?.state == .cancelled)
        #expect(OutcomeCalculator.afterSync([superseded])?.endReason == .superseded)
        #expect(OutcomeCalculator.afterSync([withdrawn, superseded])?.endReason == .withdrawn)
        #expect(OutcomeCalculator.afterSync([effective, stored(post("2026-11-15"), .mismatch)])?.state == .partiallyApplied)
        #expect(OutcomeCalculator.afterSync([effective, superseded])?.state == .effective)
        #expect(OutcomeCalculator.afterSync([effective, done]) == nil)
    }

    @Test func postIsEffectiveOnlyWhenCurrentAndOneDayAfterStart() {
        let item = stored(post("2026-11-15"), .done, ascId: "new")
        let snapshot = snapshotWith([row("old", start: "2026-01-01"), row("new", start: "2026-11-15")])
        #expect(!ItemEffectiveness.inSnapshot(item, snapshot: snapshot, today: day("2026-11-14")))
        #expect(!ItemEffectiveness.inSnapshot(item, snapshot: snapshot, today: day("2026-11-15")))
        #expect(ItemEffectiveness.inSnapshot(item, snapshot: snapshot, today: day("2026-11-16")))
        #expect(ItemEffectiveness.inSnapshot(stored(.deleteRegularPrice(ascId: "gone"), .done), snapshot: snapshot, today: day("2026-11-16")))
        #expect(!ItemEffectiveness.inSnapshot(stored(.deleteRegularPrice(ascId: "old"), .done), snapshot: snapshot, today: day("2026-11-16")))
    }

    @Test func scheduledPlanBecomesEffectiveOneDayAfterTheLastDate() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let executor = h.makeExecutor()
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        h.clock.advance(by: (37 * 86_400) + 4 * 3600)           // 2026-11-15T12:00Z
        try await executor.reconcileAfterSync(try await h.initialSync())
        #expect(try h.store.plan(id: planId)?.state == .scheduled)
        h.clock.advance(by: 86_400)                              // 2026-11-16T12:00Z
        try await executor.reconcileAfterSync(try await h.initialSync())
        #expect(try h.store.plan(id: planId)?.state == .effective)
        let item = try #require(try h.store.items(planId: planId).first)
        #expect(item.state == .effective)
        #expect(item.effectiveAt != nil)
    }

    @Test func mismatchIsLateVerifiedByTheNextSync() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let executor = h.makeExecutor(writer: GhostWriter())
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .partiallyApplied)
        _ = try await h.writer.createRegularPrice(NewRegularPrice(subscriptionId: "sub-y", territory: "GBR", planType: .upfront,
                                                                  pricePointId: "pp-sub-y-GBR-14", startDate: day("2026-11-15"), preserveCurrentPrice: true))
        try await executor.reconcileAfterSync(try await h.initialSync())
        let item = try #require(try h.store.items(planId: planId).first)
        #expect(item.state == .done)
        #expect(item.verifiedAt != nil)
        #expect(try h.audit.events(after: 0, limit: 100_000).contains { $0.type == .verify && $0.payloadJSON.contains("\"late\":true") })
        #expect(try h.store.plan(id: planId)?.state == .partiallyApplied)
    }

    @Test(arguments: [(PlanOrigin.importTable, ItemState.superseded, PlanEndReason.superseded),
                      (PlanOrigin.withdraw, ItemState.withdrawn, PlanEndReason.withdrawn)])
    func rowDeletedByALaterPlanIsMarkedWithoutAFinding(origin: PlanOrigin, itemState: ItemState, endReason: PlanEndReason) async throws {
        let h = try await ExecutorHarness.make()
        let (planA, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let executor = h.makeExecutor()
        #expect(try await executor.apply(planId: planA, confirm: Confirm.accept) == .scheduled)
        let created = try #require(try h.store.items(planId: planA).first?.ascId)
        let snapshot = try await h.initialSync()
        let deleteItems = ItemFactory.chain(cell: gbr, payloads: [.deleteRegularPrice(ascId: created)], firstSeq: 1, snapshot: snapshot, today: h.today)
        h.clock.advance(by: 60)
        let planB = try h.insertPlan(items: deleteItems, origin: origin, createdAt: h.clock.now())
        #expect(try await executor.apply(planId: planB, confirm: Confirm.accept) == .effective)
        let afterSync = try await h.initialSync()
        let findingsBefore = try h.catalog.findings(includeAcked: true).count
        try await executor.reconcileAfterSync(afterSync)
        #expect(try h.catalog.findings(includeAcked: true).count == findingsBefore)
        let item = try #require(try h.store.items(planId: planA).first)
        #expect(item.state == itemState)
        #expect(item.supersededBy == planB)
        let plan = try #require(try h.store.plan(id: planA))
        #expect(plan.state == .cancelled)
        #expect(plan.endReason == endReason)
    }

    @Test func vanishedScheduledRowMakesThePlanPartiallyApplied() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let executor = h.makeExecutor()
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        let created = try #require(try h.store.items(planId: planId).first?.ascId)
        await h.fake.mutate { model in model.regularPrices.removeAll { $0.id == created } }
        try await executor.reconcileAfterSync(try await h.initialSync())
        #expect(try h.store.items(planId: planId).first?.state == .mismatch)
        #expect(try h.store.plan(id: planId)?.state == .partiallyApplied)
    }

    @Test func closeNeedsAReason() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let executor = h.makeExecutor(writer: GhostWriter())
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .partiallyApplied)
        await #expect(throws: ExecutorError.reasonRequired) { try await executor.close(planId: planId, reason: "   ") }
        try await executor.close(planId: planId, reason: "Fixed manually in App Store Connect")
        let plan = try #require(try h.store.plan(id: planId))
        #expect(plan.state == .closed)
        #expect(plan.endReason == .abandoned)
        #expect(try h.audit.events(after: 0, limit: 100_000).contains { $0.payloadJSON.contains("Fixed manually in App Store Connect") })
    }

    @Test func replanRestPlansOnlyWhatIsMissingAndClosesThePlan() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await partiallyAppliedPlan(h)
        let executor = h.makeExecutor()
        let planner = Planner(policy: PolicyEngine(planRules: [], invariants: []))
        await #expect(throws: ExecutorError.freshTableRequired) { _ = try await executor.replanRest(planId: planId, planner: planner, rereadSheet: true) }
        let newId = try await executor.replanRest(planId: planId, planner: planner, rereadSheet: false)
        let draft = try #require(try h.store.plan(id: newId))
        #expect(draft.state == .draft)
        #expect(draft.replanOf == planId)
        #expect(try h.store.items(planId: newId).map(\.item.cell) == [jpn])
        let old = try #require(try h.store.plan(id: planId))
        #expect(old.state == .closed)
        #expect(old.endReason == .replanned)
    }

    @Test func replanRestSkipsCellsOwnedByANewerPlan() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await partiallyAppliedPlan(h)
        let snapshot = try await h.initialSync()
        h.clock.advance(by: 60)
        let newer = ItemFactory.chain(cell: jpn, payloads: [.createRegularPrice(NewRegularPrice(subscriptionId: "sub-y", territory: "JPN", planType: .upfront,
                                      pricePointId: "pp-sub-y-JPN-20", startDate: day("2026-11-20"), preserveCurrentPrice: true))],
                                      firstSeq: 1, snapshot: snapshot, today: h.today)
        _ = try h.insertPlan(items: newer, state: .scheduled, createdAt: h.clock.now())
        let newId = try await h.makeExecutor().replanRest(planId: planId, planner: Planner(policy: PolicyEngine(planRules: [], invariants: [])), rereadSheet: false)
        #expect(try h.store.items(planId: newId).isEmpty)
        #expect(try h.store.plan(id: newId)?.excluded.contains(jpn) == true)
    }

    @Test func withdrawWrittenPlansDeletesForFutureDoneItems() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await partiallyAppliedPlan(h)
        let gbrRow = try #require(try h.store.items(planId: planId).first { $0.item.cell == gbr }?.ascId)
        let newId = try await h.makeExecutor().withdrawWritten(planId: planId, planner: Planner(policy: PolicyEngine(planRules: [], invariants: [])))
        let items = try h.store.items(planId: newId)
        #expect(items.map(\.item.payload) == [.deleteRegularPrice(ascId: gbrRow)])
        let old = try #require(try h.store.plan(id: planId))
        #expect(old.state == .closed)
        #expect(old.endReason == .withdrawn)
    }

    @Test func withdrawWrittenOnScheduledPlanKeepsItScheduledUntilReconcile() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let executor = h.makeExecutor()
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        let written = try #require(try h.store.items(planId: planId).first?.ascId)
        let withdrawId = try await executor.withdrawWritten(planId: planId, planner: Planner(policy: PolicyEngine(planRules: [], invariants: [])))
        #expect(try h.store.plan(id: planId)?.state == .scheduled)
        #expect(try h.store.plan(id: withdrawId)?.origin == .withdraw)
        #expect(try h.store.items(planId: withdrawId).map(\.item.payload) == [.deleteRegularPrice(ascId: written)])
        #expect(try await executor.apply(planId: withdrawId, confirm: Confirm.accept) == .effective)
        try await executor.reconcileAfterSync(try await h.initialSync())
        #expect(try h.store.items(planId: planId).first?.state == .withdrawn)
        let plan = try #require(try h.store.plan(id: planId))
        #expect(plan.state == .cancelled)
        #expect(plan.endReason == .withdrawn)
    }

    @Test func withdrawWithNothingInTheFutureThrows() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let executor = h.makeExecutor(writer: GhostWriter())
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .partiallyApplied)
        await #expect(throws: ExecutorError.nothingToWithdraw) {
            _ = try await executor.withdrawWritten(planId: planId, planner: Planner(policy: PolicyEngine(planRules: [], invariants: [])))
        }
    }
}

/// GBR and JPN on sub-y for 2026-11-15 with a stored RegularPlanSpec; JPN's POST gets a 409, so GBR is Done and JPN Failed.
private func partiallyAppliedPlan(_ h: ExecutorHarness) async throws -> String {
    let (planId, _) = try await Scenarios.plan(h, cells: [
        Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15"),
        Scenarios.newRegularPrice(sub: "sub-y", territory: "JPN", pointIndex: 14, start: "2026-11-15"),
    ])
    try setSpec(h, planId, .regular(RegularPlanSpec(
        subscriptionIds: ["sub-y"], planType: .upfront,
        prices: [TerritoryAmount(territory: "GBR", amount: Decimal(string: "14.99")!),
                 TerritoryAmount(territory: "JPN", amount: Decimal(string: "14.99")!)],
        startDate: day("2026-11-15"), preserveCurrentPrice: true, skipIntroReplacement: [:],
        filter: PlanFilter(productAscIds: ["sub-y"], territories: ["GBR", "JPN"]))))
    let writer = SecondWriteRefused(inner: h.writer, fake: h.fake)
    #expect(try await h.makeExecutor(writer: writer).apply(planId: planId, confirm: Confirm.accept) == .partiallyApplied)
    return planId
}

/// Lets the first write through and arms a 409 for the second one.
private struct SecondWriteRefused: ASCWriting {
    let inner: any ASCWriting
    let fake: FakeASC
    func createRegularPrice(_ r: NewRegularPrice) async throws -> RegularPriceRow {
        if r.territory == "JPN" { await fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Synthetic refusal")) }
        return try await inner.createRegularPrice(r)
    }
    func deleteRegularPrice(ascId: String) async throws { try await inner.deleteRegularPrice(ascId: ascId) }
    func createIntroductoryOffer(_ r: NewIntroOffer) async throws -> IntroOfferRow { try await inner.createIntroductoryOffer(r) }
    func endIntroductoryOffer(ascId: String, endDate: CalendarDate) async throws { try await inner.endIntroductoryOffer(ascId: ascId, endDate: endDate) }
    func deleteIntroductoryOffer(ascId: String) async throws { try await inner.deleteIntroductoryOffer(ascId: ascId) }
    func createPromotionalOffer(_ r: NewPromoOffer) async throws -> PromoOffer { try await inner.createPromotionalOffer(r) }
    func replacePromotionalOfferPrices(ascId: String, prices: [NewPromoPrice]) async throws { try await inner.replacePromotionalOfferPrices(ascId: ascId, prices: prices) }
    func deletePromotionalOffer(ascId: String) async throws { try await inner.deletePromotionalOffer(ascId: ascId) }
    func replaceIAPPriceSchedule(_ r: NewIAPSchedule) async throws { try await inner.replaceIAPPriceSchedule(r) }
}
