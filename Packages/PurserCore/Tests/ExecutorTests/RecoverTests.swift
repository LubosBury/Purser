import Foundation
import Testing
import Domain
import Store
import ASCClient
@testable import Executor
import PurserTestSupport

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
}

@Suite("Recover")
struct RecoverTests {
    @Test func launchPausesEveryNonRunningApplyingPlanAsCrash() async throws {
        let h = try await ExecutorHarness.make()
        _ = try await h.initialSync()
        let fresh = try h.insertPlan(items: [], state: .applying, heartbeatAt: h.clock.now())
        let alreadyPaused = try h.insertPlan(items: [], state: .applying, pause: .user)
        let draft = try h.insertPlan(items: [])
        let paused = try await h.makeExecutor().recover(afterWake: false)
        #expect(Set(paused) == [fresh, alreadyPaused])
        #expect(try h.store.plan(id: fresh)?.pauseReason == .crash)
        #expect(try h.store.plan(id: alreadyPaused)?.pauseReason == .user)
        #expect(try h.store.plan(id: draft)?.state == .draft)
    }

    @Test func wakePausesOnlyPlansWithAStaleHeartbeat() async throws {
        let h = try await ExecutorHarness.make()
        _ = try await h.initialSync()
        let planId = try h.insertPlan(items: [], state: .applying, heartbeatAt: h.clock.now())
        let executor = h.makeExecutor()
        #expect(try await executor.recover(afterWake: true).isEmpty)
        h.clock.advance(by: AppleConstants.heartbeatSeconds * 3 + 1)
        #expect(try await executor.recover(afterWake: true) == [planId])
        #expect(try h.store.plan(id: planId)?.pauseReason == .sleep)
    }

    @Test func wakeStopsAPlanRunningInThisProcessWithSleep() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let gate = Gate()
        let reached = Locked(false)
        let executor = h.makeExecutor(writer: HoldFirstWriteWriter(inner: h.writer, gate: gate, reached: reached))
        let run = Task { try await executor.apply(planId: planId, confirm: Confirm.accept) }
        while !reached.value { await Task.yield() }
        h.clock.advance(by: 600)
        _ = try await executor.recover(afterWake: true)
        await gate.open()
        #expect(try await run.value == .applying)
        #expect(try h.store.plan(id: planId)?.pauseReason == .sleep)
        #expect(try await executor.resume(planId: planId, confirm: Confirm.accept) == .scheduled)
    }

    @Test func launchRecoveryNeverPausesAPlanWithAHeartbeatFromThisProcess() async throws {
        let h = try await ExecutorHarness.make()
        _ = try await h.initialSync()
        let launchedAt = h.clock.now()
        let previousRun = try h.insertPlan(items: [], state: .applying, heartbeatAt: launchedAt.addingTimeInterval(-600))
        h.clock.advance(by: 120)
        let liveElsewhere = try h.insertPlan(items: [], state: .applying, heartbeatAt: h.clock.now())
        let paused = try await h.makeExecutor().recover(afterWake: false, launchedAt: launchedAt)
        #expect(paused == [previousRun])
        #expect(try h.store.plan(id: previousRun)?.pauseReason == .crash)
        #expect(try h.store.plan(id: liveElsewhere)?.pauseReason == nil)
    }

    @Test func persistedRateOrNetworkPauseIsRecoveredLikeARunningPlan() async throws {
        let h = try await ExecutorHarness.make()
        _ = try await h.initialSync()
        let rate = try h.insertPlan(items: [], state: .applying, pause: .rate, heartbeatAt: h.clock.now())
        let network = try h.insertPlan(items: [], state: .applying, pause: .network, heartbeatAt: h.clock.now())
        let user = try h.insertPlan(items: [], state: .applying, pause: .user, heartbeatAt: h.clock.now())
        let paused = try await h.makeExecutor().recover(afterWake: false)
        #expect(Set(paused) == [rate, network, user])
        #expect(try h.store.plan(id: rate)?.pauseReason == .crash)
        #expect(try h.store.plan(id: network)?.pauseReason == .crash)
        #expect(try h.store.plan(id: user)?.pauseReason == .user)
    }
}
