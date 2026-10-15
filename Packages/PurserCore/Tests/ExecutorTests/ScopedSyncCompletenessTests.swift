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

/// Forwards every write; once `after` writes went through, makes every request matching `match` fail with `fault`.
private struct FaultAfterWrites: ASCWriting {
    let inner: any ASCWriting
    let fake: FakeASC
    let after: Int
    let fault: FakeFault
    let match: FakeMatch
    let count = Locked(0)

    func run<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        let result = try await operation()
        var reached = false
        count.update { written in
            written += 1
            reached = written == after
        }
        if reached { await fake.inject(fault, times: 1_000, matching: match) }
        return result
    }

    func createRegularPrice(_ r: NewRegularPrice) async throws -> RegularPriceRow { try await run { try await inner.createRegularPrice(r) } }
    func deleteRegularPrice(ascId: String) async throws { try await run { try await inner.deleteRegularPrice(ascId: ascId) } }
    func createIntroductoryOffer(_ r: NewIntroOffer) async throws -> IntroOfferRow { try await run { try await inner.createIntroductoryOffer(r) } }
    func endIntroductoryOffer(ascId: String, endDate: CalendarDate) async throws {
        try await run { try await inner.endIntroductoryOffer(ascId: ascId, endDate: endDate) }
    }
    func deleteIntroductoryOffer(ascId: String) async throws { try await run { try await inner.deleteIntroductoryOffer(ascId: ascId) } }
    func createPromotionalOffer(_ r: NewPromoOffer) async throws -> PromoOffer { try await run { try await inner.createPromotionalOffer(r) } }
    func replacePromotionalOfferPrices(ascId: String, prices: [NewPromoPrice]) async throws {
        try await run { try await inner.replacePromotionalOfferPrices(ascId: ascId, prices: prices) }
    }
    func deletePromotionalOffer(ascId: String) async throws { try await run { try await inner.deletePromotionalOffer(ascId: ascId) } }
    func replaceIAPPriceSchedule(_ r: NewIAPSchedule) async throws { try await run { try await inner.replaceIAPPriceSchedule(r) } }
    func createLocalization(versionId: String, owner: LocalizationOwner, locale: String, text: LocalizationText) async throws -> LocalizationRow {
        try await run { try await inner.createLocalization(versionId: versionId, owner: owner, locale: locale, text: text) }
    }
    func updateLocalization(localizationId: String, owner: LocalizationOwner, text: LocalizationText) async throws {
        try await run { try await inner.updateLocalization(localizationId: localizationId, owner: owner, text: text) }
    }
    func createMetadataVersion(owner: LocalizationOwner) async throws -> MetadataVersion {
        try await run { try await inner.createMetadataVersion(owner: owner) }
    }
}

private let failing = FakeFault.serverError(status: 500, applyFirst: false)

private func states(_ h: ExecutorHarness, _ planId: String) throws -> [ItemState] {
    try h.store.items(planId: planId).sorted { $0.item.seq < $1.item.seq }.map(\.state)
}

private func failedReads(_ h: ExecutorHarness, path: String) async -> [FakeRequestRecord] {
    await h.fake.requests().filter { $0.method == "GET" && $0.path == path && $0.status == 500 }
}

/// A sync is complete for a plan when the scopes its cells need were read: prices need the product's price reads (1.1),
/// texts and versions need the owner's LOCALIZATION read. A failed read of another scope neither blocks nor degrades it.
@Suite("Scoped sync completeness")
struct ScopedSyncCompletenessTests {
    // MARK: (a) a failing metadata read leaves price plans alone

    @Test func aPricePlanAppliesAndVerifiesWhileTheProductsTextsCannotBeRead() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v1/subscriptions/sub-y/versions"))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try states(h, planId) == [.effective, .done])
        #expect(try h.store.items(planId: planId).allSatisfy { $0.verifiedAt != nil })
        // Both the preflight and the verify read met the fault.
        let requests = await h.fake.requests()
        let lastWrite = try #require(requests.lastIndex { $0.isWrite })
        let firstWrite = try #require(requests.firstIndex { $0.isWrite })
        let failed = await failedReads(h, path: "/v1/subscriptions/sub-y/versions")
        #expect(failed.contains { $0.index < firstWrite })
        #expect(failed.contains { $0.index > lastWrite })
    }

    @Test func anIAPPricePlanAppliesAndVerifiesWhileItsTextsCannotBeRead() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceIAPSchedule()])
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v2/inAppPurchases/iap-life/versions"))
        let state = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        #expect(state == .scheduled || state == .effective)
        #expect(try h.store.items(planId: planId).allSatisfy { $0.verifiedAt != nil })
        #expect(try states(h, planId).allSatisfy { $0 == .done || $0 == .effective })
        #expect(await !failedReads(h, path: "/v2/inAppPurchases/iap-life/versions").isEmpty)
    }

    @Test func aTextReadFailingOnlyAfterTheWritesDoesNotTurnPricesIntoMismatch() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let writer = FaultAfterWrites(inner: h.writer, fake: h.fake, after: 2, fault: failing,
                                      match: .pathPrefix("/v1/subscriptions/sub-y/versions"))
        #expect(try await h.makeExecutor(writer: writer).apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try states(h, planId) == [.effective, .done])
        #expect(await !failedReads(h, path: "/v1/subscriptions/sub-y/versions").isEmpty)
    }

    @Test func aPricePlanCanBeReplannedWhileTheProductsTextsCannotBeRead() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")],
                                                   state: .partiallyApplied)
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v1/subscriptions/sub-y/versions"))
        let planner = Planner(policy: PolicyEngine(planRules: [], invariants: []))
        _ = try await h.makeExecutor().replanRest(planId: planId, planner: planner, freshTable: nil)
        #expect(try h.store.plan(id: planId)?.state == .closed)
        #expect(await !failedReads(h, path: "/v1/subscriptions/sub-y/versions").isEmpty)
    }

    @Test func aPricePlanCanBeRolledBackWhileTheProductsTextsCannotBeRead() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14,
                                                                                         start: "2026-11-15")])
        let executor = h.makeExecutor()
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        let written = try #require(try h.store.items(planId: planId).first?.ascId)
        let writesBefore = await h.fake.writeRequests().count
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v1/subscriptions/sub-y/versions"))
        let planner = Planner(policy: PolicyEngine(planRules: [], invariants: []))
        let withdrawId = try await executor.withdrawWritten(planId: planId, planner: planner)
        // As in 1.1: the rollback is planned from the price reads, the failed text read changes nothing.
        #expect(try h.store.plan(id: withdrawId)?.origin == .withdraw)
        #expect(try h.store.items(planId: withdrawId).map(\.item.payload) == [.deleteRegularPrice(ascId: written)])
        #expect(try h.store.plan(id: planId)?.state == .scheduled)
        #expect(await h.fake.writeRequests().count == writesBefore)
        #expect(await !failedReads(h, path: "/v1/subscriptions/sub-y/versions").isEmpty)
    }

    // MARK: (b) a text plan still needs its owner's texts

    @Test func aTextPlanRefusesToStartWhenItsOwnersTextsCannotBeRead() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await storeTextPlan(h, subNTextEdits())
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v1/subscriptions/sub-n/versions"))
        await #expect(throws: ExecutorError.syncIncomplete(.partial)) {
            _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        }
        #expect(try h.store.plan(id: planId)?.state == .draft)
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func aPausedTextPlanStaysPausedWhenItsOwnersTextsCannotBeRead() async throws {
        let h = try await ExecutorHarness.make()
        let (_, draft) = try await storeTextPlan(h, subNTextEdits())
        let planId = try h.insertPlan(items: draft.items, state: .applying, pause: .network, origin: .localization)
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v1/subscriptions/sub-n/versions"))
        await #expect(throws: ExecutorError.syncIncomplete(.partial)) {
            _ = try await h.makeExecutor().resume(planId: planId, confirm: Confirm.accept)
        }
        let plan = try #require(try h.store.plan(id: planId))
        #expect(plan.state == .applying)
        #expect(plan.pauseReason == .network)
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func textsAreNotVerifiedByAReadThatFailedForTheirOwner() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, draft) = try await storeTextPlan(h, subNTextEdits())
        let writer = FaultAfterWrites(inner: h.writer, fake: h.fake, after: draft.items.count, fault: failing,
                                      match: .pathPrefix("/v1/subscriptions/sub-n/versions"))
        _ = try await h.makeExecutor(writer: writer).apply(planId: planId, confirm: Confirm.accept)
        #expect(try states(h, planId) == [.mismatch, .mismatch])
        #expect(try h.store.items(planId: planId).allSatisfy { $0.verifiedAt == nil })
    }

    @Test func aTextPlanIsNotBlockedByAFailingPriceReadOfItsOwner() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await storeTextPlan(h, subNTextEdits())
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v1/subscriptions/sub-n/prices"))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .effective)
        #expect(try states(h, planId) == [.effective, .effective])
        #expect(await !failedReads(h, path: "/v1/subscriptions/sub-n/prices").isEmpty)
    }

    // MARK: (c) a failing price read behaves as in 1.1

    /// As in 1.1, a regular price plan needs every price read of its product, not only the regular prices.
    @Test(arguments: ["prices", "introductoryOffers", "promotionalOffers"])
    func aPricePlanRefusesToStartWhenAPriceReadOfItsProductFails(read: String) async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v1/subscriptions/sub-y/\(read)"))
        await #expect(throws: ExecutorError.syncIncomplete(.partial)) {
            _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        }
        #expect(try h.store.plan(id: planId)?.state == .draft)
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(await !failedReads(h, path: "/v1/subscriptions/sub-y/\(read)").isEmpty)
    }

    @Test func anIAPPricePlanRefusesToStartWhenItsScheduleCannotBeRead() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceIAPSchedule()])
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v2/inAppPurchases/iap-life/iapPriceSchedule"))
        await #expect(throws: ExecutorError.syncIncomplete(.partial)) {
            _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        }
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func aPricePlanRefusesToStartWhenItsPricePointsCannotBeRead() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        // Price points are read again once they are older than a week.
        h.clock.advance(by: 8 * 24 * 3_600)
        await h.fake.inject(failing, times: 1_000, matching: .pathPrefix("/v1/subscriptions/sub-y/pricePoints"))
        await #expect(throws: ExecutorError.syncIncomplete(.partial)) {
            _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        }
        #expect(await !failedReads(h, path: "/v1/subscriptions/sub-y/pricePoints").isEmpty)
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func pricesAreNotVerifiedByAReadThatFailedForTheirProduct() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let writer = FaultAfterWrites(inner: h.writer, fake: h.fake, after: 2, fault: failing,
                                      match: .pathPrefix("/v1/subscriptions/sub-y/prices"))
        _ = try await h.makeExecutor(writer: writer).apply(planId: planId, confirm: Confirm.accept)
        #expect(try states(h, planId) == [.mismatch, .mismatch])
        #expect(try h.store.items(planId: planId).allSatisfy { $0.verifiedAt == nil })
    }
}
