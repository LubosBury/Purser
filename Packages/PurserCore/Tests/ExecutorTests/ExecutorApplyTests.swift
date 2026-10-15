import Foundation
import Testing
import Domain
import Store
import Audit
import ASCClient
import Catalog
import Policy
import Planner
import PurserSecurity
@testable import Executor
import PurserTestSupport

/// Records the reason of every Touch ID prompt and allows it.
private struct RecordingGate: BiometricGate {
    let reasons = Locked<[String]>([])
    func authenticate(reason: String) async throws { reasons.update { $0.append(reason) } }
}

private struct FixedRule: PlanRule {
    let id: RuleID
    let severity: Severity
    func evaluate(_ context: PolicyContext) -> [Verdict] {
        [Verdict(rule: id, severity: severity, cell: context.items.first?.cell, message: "test rule \(id)",
                 riskClass: severity == .confirm(.c2) ? "R7 decrease" : nil)]
    }
}

private func states(_ h: ExecutorHarness, _ planId: String) throws -> [ItemState] {
    try h.store.items(planId: planId).sorted { $0.item.seq < $1.item.seq }.map(\.state)
}

@Suite("Executor apply")
struct ExecutorApplyTests {
    @Test func appliesReplacePairEndToEnd() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let state = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        #expect(state == .scheduled)
        #expect(try states(h, planId) == [.effective, .done])
        #expect(try h.store.items(planId: planId).allSatisfy { $0.verifiedAt != nil })
        let model = await h.fake.model
        #expect(!model.regularPrices.contains { $0.id == "price-sched-sub-y-CZE" })
        #expect(model.regularPrices.contains {
            $0.subscriptionId == "sub-y" && $0.territory == "CZE" && $0.pricePointId == "pp-sub-y-CZE-12" && $0.startDate == CalendarDate(iso: "2026-11-20")
        })
        #expect(await h.fake.duplicates().isEmpty)
        let events = try h.audit.events(after: 0, limit: 100_000)
        let sent = events.filter { $0.type == .httpSent }
        let received = events.filter { $0.type == .httpReceived }
        #expect(sent.count == 2)
        #expect(received.count == 2)
        #expect(zip(sent, received).allSatisfy { $0.seq < $1.seq })
        #expect(try h.audit.verifyChain() == .ok(count: events.count))
        let plan = try #require(try h.store.plan(id: planId))
        #expect(plan.productStates == ["sub-y": .approved])
        #expect(plan.heartbeatAt != nil)
        #expect(plan.reason == "Synthetic test run approved by the owner")
    }

    @Test func touchIDAsksToApplyOrResumeAPlanOfAnyKind() async throws {
        let h = try await ExecutorHarness.make()
        let gate = RecordingGate()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        _ = try await h.makeExecutor(gate: gate).apply(planId: planId, confirm: Confirm.accept)
        let paused = try h.insertPlan(items: [], state: .applying, pause: .user)
        _ = try? await h.makeExecutor(gate: gate).resume(planId: paused, confirm: Confirm.accept)
        #expect(gate.reasons.value == ["Apply a plan to FruitJar", "Resume a plan on FruitJar"])
    }

    @Test func httpSentAndInFlightAreCommittedBeforeEveryRequest() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE"),
                                                             Scenarios.newIntro(sub: "sub-m", territory: "USA", start: "2026-11-01")])
        let seen = Locked<[String]>([])
        let probe = ProbeWriter(inner: h.writer) {
            let last = (try? h.audit.events(after: 0, limit: 100_000))?.last?.type
            let inFlight = ((try? h.store.items(planId: planId)) ?? []).filter { $0.state == .inFlight }.count
            seen.update { $0.append("\(last.map { "\($0)" } ?? "none")|\(inFlight)") }
        }
        _ = try await h.makeExecutor(writer: probe).apply(planId: planId, confirm: Confirm.accept)
        #expect(seen.value == ["httpSent|1", "httpSent|1", "httpSent|1"])
    }

    @Test func httpSentCarriesKeyIdAndTheTokenIdButNeverTheToken() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        let sent = try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .httpSent }
        let payloads = sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.payloadJSON.utf8))) as? [String: Any] }
        #expect(payloads.count == 2)
        #expect(payloads.allSatisfy { $0["keyId"] as? String == "TESTKEY001" })
        let tokenIds = payloads.compactMap { $0["jti"] as? String }
        #expect(tokenIds.count == 2)
        #expect(tokenIds.allSatisfy { $0.count == 36 })
        #expect(sent.allSatisfy { !$0.payloadJSON.contains("eyJ") && !$0.payloadJSON.contains("Bearer") })
        let writes = await h.fake.writeRequests()
        #expect(writes.compactMap { $0.tokenId } == tokenIds)
        let received = try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .httpReceived }
        #expect(received.allSatisfy { $0.payloadJSON.contains("\"status\":") })
    }

    @Test func individualKeyAppliesThroughFakeASC() async throws {
        let h = try await ExecutorHarness.make(keyKind: .individual)
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        let requests = await h.fake.requests()
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.identity == "individual" })
    }

    @Test func plannerDraftIsAppliedAndLiveStateMatchesEveryTarget() async throws {
        let h = try await ExecutorHarness.make()
        let snapshot = try await h.initialSync()
        let spec = PlanSpec.intro(IntroPlanSpec(subscriptionIds: ["sub-n"], mode: .freeTrial, duration: .oneWeek, numberOfPeriods: 1,
                                                pricing: .freeTrial, startDate: CalendarDate(iso: "2026-11-01"), endDate: nil,
                                                nominalDiscount: nil, filter: PlanFilter(territories: ["CZE", "USA"]), canary: false))
        let draft = try Planner(policy: PolicyEngine(planRules: [], invariants: []))
            .plan(spec, context: PlanningContext(snapshot: snapshot, config: h.config, today: h.today))
        #expect(draft.items.count == 2)
        let planId = try PlanPersistence(store: h.store, audit: h.audit, appBuild: "test")
            .saveDraft(draft, binding: PlanBinding(config: h.config), reason: nil, replanOf: nil)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        let live = try await h.initialSync()
        for item in draft.items {
            #expect(Reconciler.matches(live: live.cellState(item.cell, on: h.today), expected: item.target, today: h.today),
                    "the K9 placeholder id in \(item.cell) must match the created row")
        }
    }

    private static let cloneTitle = "Clone com.example.c of com.example.s: regular prices (apply first)"

    @Test(arguments: [nil, "", "   "] as [String?])
    func applyingWithoutAConfirmationReasonKeepsTheDraftsTitle(reason: String?) async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        try h.updatePlan(planId) { $0.reason = Self.cloneTitle }
        let silent = ConfirmationResponse(accepted: true, acknowledgedExclusions: true, typedAppName: nil, reason: reason, checkedRiskClasses: [])
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.responding(silent)) == .scheduled)
        #expect(try h.store.plan(id: planId)?.reason == Self.cloneTitle)
        #expect(CloneDrafts.openDrafts(in: try h.store.plans(states: nil)) == [Self.cloneTitle: planId])
    }

    @Test func applyingWithAConfirmationReasonRecordsIt() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        try h.updatePlan(planId) { $0.reason = Self.cloneTitle }
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try h.store.plan(id: planId)?.reason == "Synthetic test run approved by the owner")
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func resumingWithoutAConfirmationReasonKeepsThePlansTitle(reason: String?) async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")], state: .applying)
        try h.updatePlan(planId) { $0.reason = Self.cloneTitle; $0.pauseReason = .user }
        // A new warning changes the verdict hash, so the resume asks for a confirmation again.
        let executor = h.makeExecutor(policy: PolicyEngine(planRules: [FixedRule(id: "R9", severity: .warn)], invariants: []))
        let silent = ConfirmationResponse(accepted: true, acknowledgedExclusions: true, typedAppName: nil, reason: reason, checkedRiskClasses: [])
        #expect(try await executor.resume(planId: planId, confirm: Confirm.responding(silent)) == .scheduled)
        let plan = try #require(try h.store.plan(id: planId))
        #expect(plan.verdicts.map(\.rule) == ["R9"])
        #expect(plan.reason == Self.cloneTitle)
    }

    @Test func declinedConfirmationReturnsToDraftWithZeroWrites() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let state = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.decline)
        #expect(state == .draft)
        #expect(try h.store.plan(id: planId)?.state == .draft)
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(try h.audit.events(after: 0, limit: 100_000).contains { $0.type == .confirmation })
    }

    @Test func productionWorkspaceNeedsTheTypedAppName() async throws {
        let h = try await ExecutorHarness.make(isProduction: true)
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let executor = h.makeExecutor()
        let wrong = ConfirmationResponse(accepted: true, acknowledgedExclusions: true, typedAppName: "Fruitjar", reason: nil, checkedRiskClasses: [])
        #expect(try await executor.apply(planId: planId, confirm: Confirm.responding(wrong)) == .draft)
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .scheduled)
    }

    @Test func c2NeedsReasonAndEveryRiskClass() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let executor = h.makeExecutor(policy: PolicyEngine(planRules: [FixedRule(id: "R7", severity: .confirm(.c2))], invariants: []))
        let short = ConfirmationResponse(accepted: true, acknowledgedExclusions: true, typedAppName: "FruitJar", reason: "too short",
                                         checkedRiskClasses: ["R7 decrease"])
        #expect(try await executor.apply(planId: planId, confirm: Confirm.responding(short)) == .draft)
        let unchecked = ConfirmationResponse(accepted: true, acknowledgedExclusions: true, typedAppName: "FruitJar",
                                             reason: "Synthetic decrease approved for testing", checkedRiskClasses: [])
        #expect(try await executor.apply(planId: planId, confirm: Confirm.responding(unchecked)) == .draft)
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(try await executor.apply(planId: planId, confirm: Confirm.accept) == .scheduled)
        #expect(try h.store.plan(id: planId)?.confirmationLevel == .c2)
    }

    @Test func excludedCellsMustBeAcknowledged() async throws {
        let h = try await ExecutorHarness.make()
        let excludedCell = CellKey.regular(subscriptionId: "sub-y", territory: "JPN", planType: .upfront)
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")],
                                                   excluded: [excludedCell])
        let noAck = ConfirmationResponse(accepted: true, acknowledgedExclusions: false, typedAppName: nil, reason: nil, checkedRiskClasses: [])
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.responding(noAck)) == .draft)
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func firstStartDifferenceMakesPlanStaleWithZeroWrites() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        await h.fake.mutate { model in
            let index = model.regularPrices.firstIndex { $0.id == "price-sched-sub-y-CZE" }!
            model.regularPrices[index].pricePointId = "pp-sub-y-CZE-15"
        }
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .stale)
        #expect(try states(h, planId) == [.stale, .skipped])
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func deadlineRecheckRightBeforeSendingMakesItemStale() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-10-12")])
        h.clock.advance(by: 2 * 86_400)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .stale)
        #expect(try states(h, planId) == [.stale])
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func reconcileBeforeSendFindsAnExistingTargetWithoutWriting() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.mutate { model in
            model.intros.append(FakeIntro(id: "intro-existing", subscriptionId: "sub-n", territory: "USA", planType: .upfront, mode: .freeTrial,
                                          duration: .oneWeek, numberOfPeriods: 1, startDate: nil, endDate: nil, pricePointId: nil,
                                          createdOn: CalendarDate(iso: "2026-10-01")!))
        }
        let snapshot = try await h.initialSync()
        let cell = CellKey.intro(subscriptionId: "sub-n", territory: "USA", planType: .upfront)
        let live = snapshot.cellState(cell, on: h.today)
        let item = PlannedItem(seq: 1, cell: cell, payload: .createIntro(NewIntroOffer(subscriptionId: "sub-n", territory: "USA", planType: .upfront,
                               mode: .freeTrial, duration: .oneWeek, numberOfPeriods: 1, startDate: nil, endDate: nil, pricePointId: nil)),
                               before: live, target: live)
        let planId = try h.insertPlan(items: [item])
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .effective)
        #expect(try h.store.items(planId: planId).first?.ascId == "intro-existing")
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func verifyMarksMismatchAfterThreeReadsWithinTheWindow() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let started = h.clock.now()
        #expect(try await h.makeExecutor(writer: GhostWriter()).apply(planId: planId, confirm: Confirm.accept) == .partiallyApplied)
        #expect(try states(h, planId) == [.mismatch])
        #expect(try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .verify }.count == AppleConstants.verifyAttempts)
        let elapsed = h.clock.now().timeIntervalSince(started)
        #expect(elapsed >= AppleConstants.verifyWindowSeconds)
        #expect(elapsed < AppleConstants.verifyWindowSeconds + 60)
    }

    @Test func eventsReportItemStatesProgressAndFinalState() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let executor = h.makeExecutor()
        let collector = Task { () -> [ExecutorEvent] in
            var seen: [ExecutorEvent] = []
            for await event in executor.events {
                seen.append(event)
                if case let .planState(_, state, _) = event, state == .scheduled { break }
            }
            return seen
        }
        _ = try await executor.apply(planId: planId, confirm: Confirm.accept)
        let events = await collector.value
        #expect(events.contains { if case .planState(_, .applying, nil) = $0 { return true }; return false })
        #expect(events.contains { if case .item(_, 1, .inFlight) = $0 { return true }; return false })
        #expect(events.contains { if case let .progress(_, done, total, _, _) = $0 { return done == 2 && total == 2 }; return false })
    }

    @Test func a3RefusesSecondApplyingPlan() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.replaceScheduledRegular(territory: "CZE")])
        let other = try h.insertPlan(items: [], state: .applying)
        await #expect(throws: ExecutorError.anotherPlanApplying(other)) {
            _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        }
        #expect(try h.store.plan(id: planId)?.state == .draft)
    }
}
