import Foundation
import Testing
import Domain
import Store
import Audit
@testable import Executor
import PurserTestSupport

private struct SimulatedCrash: Error {}

/// Crashes the first executor at `crashStep`, then restarts with recover() + resume().
private func crashAndResume(_ h: ExecutorHarness, planId: String, at crashStep: ExecutorStep) async throws -> PlanState {
    let first = h.makeExecutor()
    await first.setStepHook { step in if step == crashStep { throw SimulatedCrash() } }
    do {
        _ = try await first.apply(planId: planId, confirm: Confirm.accept)
        Issue.record("the simulated crash did not happen")
    } catch is SimulatedCrash {
    }
    h.clock.advance(by: AppleConstants.heartbeatSeconds * 4)
    let second = h.makeExecutor()
    #expect(try await second.recover(afterWake: false) == [planId])
    return try await second.resume(planId: planId, confirm: Confirm.accept)
}

@Suite("Localization crash and resume")
struct LocalizationCrashResumeTests {
    @Test func aCrashAfterTheResponseResumesByReadingAndFindsTheTarget() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await storeTextPlan(h, subNTextEdits())
        #expect(try await crashAndResume(h, planId: planId, at: .afterResponse(seq: 1)) == .effective)
        let stored = try h.store.items(planId: planId).sorted { $0.item.seq < $1.item.seq }
        #expect(stored.map(\.state) == [.effective, .effective])
        #expect(await h.fake.writeRequests().map(\.method) == ["POST", "PATCH"])
        let model = await h.fake.model
        let posted = model.localizations.filter { $0.locale == "cs" && $0.text.name == "Ročně nové" }
        #expect(posted.count == 1)
        // The asc_id the read found after the crash is the id of the localization the POST created.
        let created = try #require(posted.first)
        #expect(stored[0].ascId == created.id)
        #expect(try h.catalog.findings(includeAcked: false).filter { $0.cell.productAscId == "sub-n" }.isEmpty)
    }

    @Test func aCrashAfterHTTPSentSendsTheTextOnce() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await storeTextPlan(h, subNTextEdits())
        #expect(try await crashAndResume(h, planId: planId, at: .afterHTTPSent(seq: 1)) == .effective)
        #expect(await h.fake.writeRequests().map(\.method) == ["POST", "PATCH"])
        let sent = try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .httpSent }
        #expect(sent.count == 3)
        #expect(await h.fake.duplicates().isEmpty)
    }
}
