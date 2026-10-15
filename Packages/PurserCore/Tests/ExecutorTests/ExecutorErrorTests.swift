import Foundation
import Testing
import Domain
import Store
import Audit
import PurserSecurity
import ASCClient
@testable import Executor
import PurserTestSupport

private struct GateDenied: Error {}

/// Touch ID that the owner refuses.
private struct DenyingGate: BiometricGate {
    func authenticate(reason: String) async throws { throw GateDenied() }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Holds the first write until the gate opens, so a test can pause or abort while a request is in flight.
private struct HoldFirstWriteWriter: ASCWriting {
    let inner: any ASCWriting
    let gate: Gate
    let reached: Locked<Bool>
    func hold() async {
        guard !reached.value else { return }
        reached.update { $0 = true }
        await gate.wait()
    }
    func createRegularPrice(_ r: NewRegularPrice) async throws -> RegularPriceRow { await hold(); return try await inner.createRegularPrice(r) }
    func deleteRegularPrice(ascId: String) async throws { await hold(); try await inner.deleteRegularPrice(ascId: ascId) }
    func createIntroductoryOffer(_ r: NewIntroOffer) async throws -> IntroOfferRow { await hold(); return try await inner.createIntroductoryOffer(r) }
    func endIntroductoryOffer(ascId: String, endDate: CalendarDate) async throws { await hold(); try await inner.endIntroductoryOffer(ascId: ascId, endDate: endDate) }
    func deleteIntroductoryOffer(ascId: String) async throws { await hold(); try await inner.deleteIntroductoryOffer(ascId: ascId) }
    func createPromotionalOffer(_ r: NewPromoOffer) async throws -> PromoOffer { await hold(); return try await inner.createPromotionalOffer(r) }
    func replacePromotionalOfferPrices(ascId: String, prices: [NewPromoPrice]) async throws { await hold(); try await inner.replacePromotionalOfferPrices(ascId: ascId, prices: prices) }
    func deletePromotionalOffer(ascId: String) async throws { await hold(); try await inner.deletePromotionalOffer(ascId: ascId) }
    func replaceIAPPriceSchedule(_ r: NewIAPSchedule) async throws { await hold(); try await inner.replaceIAPPriceSchedule(r) }
    func createLocalization(versionId: String, owner: LocalizationOwner, locale: String, text: LocalizationText) async throws -> LocalizationRow {
        await hold(); return try await inner.createLocalization(versionId: versionId, owner: owner, locale: locale, text: text)
    }
    func updateLocalization(localizationId: String, owner: LocalizationOwner, text: LocalizationText) async throws {
        await hold(); try await inner.updateLocalization(localizationId: localizationId, owner: owner, text: text)
    }
    func createMetadataVersion(owner: LocalizationOwner) async throws -> MetadataVersion {
        await hold(); return try await inner.createMetadataVersion(owner: owner)
    }
}

/// Injects a FakeASC fault right after a write failed, so the executor's next read meets it.
private struct InjectAfterFailureWriter: ASCWriting {
    let inner: any ASCWriting
    let fake: FakeASC
    let fault: FakeFault
    let match: FakeMatch
    func run<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() } catch {
            await fake.inject(fault, times: 1, matching: match)
            throw error
        }
    }
    func createRegularPrice(_ r: NewRegularPrice) async throws -> RegularPriceRow { try await run { try await inner.createRegularPrice(r) } }
    func deleteRegularPrice(ascId: String) async throws { try await run { try await inner.deleteRegularPrice(ascId: ascId) } }
    func createIntroductoryOffer(_ r: NewIntroOffer) async throws -> IntroOfferRow { try await run { try await inner.createIntroductoryOffer(r) } }
    func endIntroductoryOffer(ascId: String, endDate: CalendarDate) async throws { try await run { try await inner.endIntroductoryOffer(ascId: ascId, endDate: endDate) } }
    func deleteIntroductoryOffer(ascId: String) async throws { try await run { try await inner.deleteIntroductoryOffer(ascId: ascId) } }
    func createPromotionalOffer(_ r: NewPromoOffer) async throws -> PromoOffer { try await run { try await inner.createPromotionalOffer(r) } }
    func replacePromotionalOfferPrices(ascId: String, prices: [NewPromoPrice]) async throws { try await run { try await inner.replacePromotionalOfferPrices(ascId: ascId, prices: prices) } }
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

private func classify(_ status: Int, _ code: String?, _ detail: String? = nil) -> WriteErrorClass {
    ErrorClassifier.classify(.http(status: status, code: code, title: nil, detail: detail))
}

private func onePrice(_ h: ExecutorHarness) async throws -> String {
    try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")]).planId
}

private func newPrices(sub: String, territories: [TerritoryCode], pointIndex: Int) -> [ScenarioCell] {
    territories.map { Scenarios.newRegularPrice(sub: sub, territory: $0, pointIndex: pointIndex, start: "2026-11-15") }
}

private func states(_ h: ExecutorHarness, _ planId: String) throws -> [ItemState] {
    try h.store.items(planId: planId).sorted { $0.item.seq < $1.item.seq }.map(\.state)
}

private func gbrRows(_ h: ExecutorHarness) async -> Int {
    await h.fake.model.regularPrices.filter { $0.subscriptionId == "sub-y" && $0.territory == "GBR" }.count
}

private func pauseReason(_ h: ExecutorHarness, _ planId: String) throws -> PauseReason? { try h.store.plan(id: planId)?.pauseReason }

private func forcePlan(_ h: ExecutorHarness, _ planId: String, _ state: PlanState, pause: PauseReason?) throws {
    try h.updatePlan(planId) { plan in
        plan.state = state
        plan.pauseReason = pause
    }
}

private func pauseEvents(_ h: ExecutorHarness, _ reason: PauseReason) throws -> Int {
    try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .planStateChanged && $0.payloadJSON.contains("\"pause\":\"\(reason.rawValue)\"") }.count
}

@Suite("Executor errors and pauses")
struct ExecutorErrorTests {
    @Test func classifierMapsEverySignal() {
        #expect(ErrorClassifier.classify(.rateLimited) == .rateLimited)
        #expect(ErrorClassifier.classify(.network(description: "timed out", maybeSent: true)) == .maybeApplied)
        #expect(ErrorClassifier.classify(.network(description: "offline", maybeSent: false)) == .notSent)
        #expect(ErrorClassifier.classify(.decoding("bad json")) == .maybeApplied)
        #expect(ErrorClassifier.classify(.readOnlyClient) == .refused)
        #expect(ErrorClassifier.classify(.foreignResource("x")) == .refused)
        #expect(classify(401, "NOT_AUTHORIZED") == .unauthorized)
        #expect(classify(403, "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED") == .agreement)
        #expect(classify(403, "FORBIDDEN_ERROR") == .forbidden)
        #expect(classify(409, "ENTITY_ERROR", "Pricing change is not allowed") == .agreement)
        #expect(classify(409, "ENTITY_ERROR", "Must delete future price change before creating a new one") == .mustDeleteFuture)
        #expect(classify(409, "ENTITY_ERROR", "Only future price changes can be deleted") == .onlyFutureDeletable)
        #expect(classify(409, "ENTITY_ERROR", "Something else") == .conflict(409))
        #expect(classify(422, "ENTITY_UNPROCESSABLE") == .conflict(422))
        #expect(classify(429, "RATE_LIMIT_EXCEEDED") == .rateLimited)
        #expect(classify(503, nil) == .serverError(503))
    }

    @Test func timeoutAfterSendStaysInFlightAndIsResolvedByAFreshRead() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.timeoutAfterApply)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(await gbrRows(h) == 2)
        #expect(await h.fake.duplicates().isEmpty)
        #expect(await h.fake.writeRequests().count == 1)
        #expect(try h.store.items(planId: planId).first?.attempts == 1)
    }

    @Test func timeoutWithAFailingReadPausesNetworkAndResumesItself() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.timeoutAfterApply)
        let writer = InjectAfterFailureWriter(inner: h.writer, fake: h.fake, fault: .networkBeforeSend, match: .reads)
        let started = h.clock.now()
        #expect(try await h.makeExecutor(writer: writer).apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try pauseEvents(h, .network) >= 1)
        #expect(h.clock.now().timeIntervalSince(started) >= 60)
        #expect(await gbrRows(h) == 2)
        #expect(await h.fake.writeRequests().count == 1)
    }

    @Test func rateLimitPausesRateWithBackoffAndResumesItself() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.rateLimited, times: 2)
        let started = h.clock.now()
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try pauseEvents(h, .rate) >= 1)
        #expect(h.clock.now().timeIntervalSince(started) >= Double(AppleConstants.rateBackoffMinutes[0] + AppleConstants.rateBackoffMinutes[1]) * 60)
        #expect(await gbrRows(h) == 2)
        #expect(await h.fake.duplicates().isEmpty)
    }

    @Test func networkErrorBeforeSendingPausesNetworkAndRetries() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.networkBeforeSend)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try pauseEvents(h, .network) >= 1)
        #expect(await gbrRows(h) == 2)
    }

    @Test func serverErrorIsReadThenRetriedAndSucceeds() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.serverError(status: 500, applyFirst: false), times: 2)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try h.store.items(planId: planId).first?.attempts == 3)
        #expect(await gbrRows(h) == 2)
    }

    @Test func appliedServerErrorIsFoundByTheFreshRead() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.serverError(status: 500, applyFirst: true))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try h.store.items(planId: planId).first?.attempts == 1)
        #expect(await gbrRows(h) == 2)
        #expect(await h.fake.duplicates().isEmpty)
    }

    @Test func threeServerErrorsFailTheItemAndPauseSystemic() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.serverError(status: 503, applyFirst: false), times: 3)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .applying)
        #expect(try pauseReason(h, planId) == .systemic)
        #expect(try states(h, planId) == [.failed])
        #expect(try h.store.items(planId: planId).first?.attempts == AppleConstants.maxServerErrorAttempts)
        #expect(await gbrRows(h) == 1)
    }

    @Test func unauthorizedIsRetriedOnceWithANewToken() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.unauthorized)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
    }

    @Test func secondUnauthorizedPausesAuth() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.unauthorized, times: 2)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .applying)
        #expect(try pauseReason(h, planId) == .auth)
        #expect(try states(h, planId) == [.pending])
    }

    @Test(arguments: [FakeFault.agreementMissing403, FakeFault.pricingNotAllowed])
    func agreementSignalsPauseAgreement(fault: FakeFault) async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(fault)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .applying)
        #expect(try pauseReason(h, planId) == .agreement)
        #expect(try states(h, planId) == [.pending])
        #expect(await gbrRows(h) == 1)
    }

    @Test func otherForbiddenPausesAuth() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.serverError(status: 403, applyFirst: false))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .applying)
        #expect(try pauseReason(h, planId) == .auth)
    }

    @Test func mustDeleteFutureChangeMakesTheItemStale() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Must delete future price change before creating a new one"))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .stale)
        #expect(try states(h, planId) == [.stale])
    }

    @Test func onlyFutureDeletableFailsTheDeleteAndSkipsThePairedPost() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        await h.fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Only future price changes can be deleted"), matching: .method("DELETE"))
        _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        #expect(try states(h, planId) == [.failed, .skipped])
        let stored = try #require(try h.store.items(planId: planId).first)
        #expect(stored.errorJSON?.contains("Only future price changes can be deleted") == true)
    }

    @Test func otherConflictWithoutTheTargetFails() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.conflict(code: "ENTITY_ERROR.ATTRIBUTE.INVALID", detail: "Something unexpected"))
        _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        #expect(try states(h, planId) == [.failed])
        #expect(try h.audit.events(after: 0, limit: 100_000).contains { $0.type == .httpReceived && $0.payloadJSON.contains("Something unexpected") })
    }

    @Test func otherConflictWithTheTargetPresentIsDone() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.serverError(status: 409, applyFirst: true))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try states(h, planId) == [.done])
    }

    @Test func theSameErrorThreeTimesInARowPausesSystemic() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: newPrices(sub: "sub-y", territories: ["GBR", "JPN", "USA", "DEU"], pointIndex: 14))
        await h.fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Unexpected"), times: 3)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .applying)
        #expect(try pauseReason(h, planId) == .systemic)
        #expect(try states(h, planId) == [.failed, .failed, .failed, .pending])
    }

    @Test func errorsOnMoreThanFivePercentOfItemsPauseSystemic() async throws {
        let h = try await ExecutorHarness.make()
        let all: [TerritoryCode] = ["USA", "CZE", "DEU", "FRA", "GBR", "JPN"]
        let (planId, _) = try await Scenarios.plan(h, cells: newPrices(sub: "sub-y", territories: all, pointIndex: 14)
                                                   + newPrices(sub: "sub-m", territories: all, pointIndex: 5))
        await h.fake.inject(.conflict(code: "CODE_A", detail: "a"))
        await h.fake.inject(.conflict(code: "CODE_B", detail: "b"))
        await h.fake.inject(.conflict(code: "CODE_C", detail: "c"))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .applying)
        #expect(try pauseReason(h, planId) == .systemic)
        let result = try states(h, planId)
        #expect(result.prefix(3).allSatisfy { $0 == .failed })
        #expect(result.dropFirst(3).allSatisfy { $0 == .pending })
    }

    @Test func userPauseStopsAtTheItemBoundaryAndResumeFinishes() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let gate = Gate()
        let reached = Locked(false)
        let executor = h.makeExecutor(writer: HoldFirstWriteWriter(inner: h.writer, gate: gate, reached: reached))
        let run = Task { try await executor.apply(planId: planId, confirm: Confirm.accept) }
        while !reached.value { await Task.yield() }
        await executor.pause(planId: planId, reason: .user)
        await gate.open()
        #expect(try await run.value == .applying)
        #expect(try pauseReason(h, planId) == .user)
        #expect(try states(h, planId) == [.done, .pending])
        #expect(try await executor.resume(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try states(h, planId) == [.effective, .done])
        #expect(await h.fake.duplicates().isEmpty)
    }

    @Test func abortDuringARunDrainsAndReportsPartiallyApplied() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let gate = Gate()
        let reached = Locked(false)
        let executor = h.makeExecutor(writer: HoldFirstWriteWriter(inner: h.writer, gate: gate, reached: reached))
        let run = Task { try await executor.apply(planId: planId, confirm: Confirm.accept) }
        while !reached.value { await Task.yield() }
        let abort = Task { try await executor.abort(planId: planId) }
        while await !executor.abortRequests.contains(planId) { await Task.yield() }
        await gate.open()
        #expect(try await run.value == .partiallyApplied)
        #expect(try await abort.value == .partiallyApplied)
        #expect(try states(h, planId) == [.done, .skipped])
    }

    @Test func abortWithoutWritesCancelsThePlan() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        try forcePlan(h, planId, .applying, pause: .user)
        #expect(try await h.makeExecutor().abort(planId: planId) == .cancelled)
        let plan = try #require(try h.store.plan(id: planId))
        #expect(plan.endReason == .abortedNoWrites)
        #expect(try states(h, planId) == [.skipped, .skipped])
    }

    @Test func lostScheduledChangeIsFlaggedWhenThePostAfterTheDeleteFails() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        await h.fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Synthetic refusal"), matching: .method("POST"))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .partiallyApplied)
        let items = try h.store.items(planId: planId).sorted { $0.item.seq < $1.item.seq }
        #expect(items.map(\.state) == [.effective, .failed])
        #expect(items[0].item.flags == [.lostScheduledChange])
        #expect(items[1].item.flags.isEmpty)
        #expect(try h.audit.events(after: 0, limit: 100_000).contains {
            $0.type == .itemStateChanged && $0.payloadJSON.contains("LOST_SCHEDULED_CHANGE")
        })
    }

    @Test func noOfferIsFlaggedWhenThePostAfterPatchEndFails() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.endLiveIntroThenPost(territory: "DEU")])
        await h.fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Synthetic refusal"), matching: .method("POST"))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .partiallyApplied)
        let items = try h.store.items(planId: planId).sorted { $0.item.seq < $1.item.seq }
        #expect(items.map(\.state) == [.done, .failed])
        #expect(items[0].item.flags == [.noOffer])
    }

    @Test func persistedRatePauseNeedsTouchIDOnResume() async throws {
        let h = try await ExecutorHarness.make()
        let planId = try await onePrice(h)
        await h.fake.inject(.rateLimited, times: Executor.maxAutomaticWaits + 1)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .applying)
        #expect(try pauseReason(h, planId) == .rate)
        let writesBefore = await h.fake.writeRequests().count
        await #expect(throws: GateDenied.self) {
            _ = try await h.makeExecutor(gate: DenyingGate()).resume(planId: planId, confirm: Confirm.accept)
        }
        #expect(await h.fake.writeRequests().count == writesBefore)
        #expect(try pauseReason(h, planId) == .rate)
        #expect(try await h.makeExecutor().resume(planId: planId, confirm: Confirm.accept) == .scheduled)
    }

    @Test func abortReadsInFlightItemsBeforeDeciding() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        try forcePlan(h, planId, .applying, pause: .crash)
        try h.setItemState(planId: planId, seq: 1, .inFlight)
        try await h.writer.deleteRegularPrice(ascId: "price-sched-sub-y-CZE")
        #expect(try await h.makeExecutor().abort(planId: planId) == .partiallyApplied)
        #expect(try states(h, planId) == [.done, .skipped])
    }
}
