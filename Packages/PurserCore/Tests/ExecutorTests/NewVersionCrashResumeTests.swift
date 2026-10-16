import Foundation
import Testing
import Domain
import Store
import Audit
import ASCClient
import Policy
@testable import Executor
import PurserTestSupport

private struct SimulatedCrash: Error {}

/// Crashes the first executor at `crash`, then recovers and resumes with a second one (as LocalizationCrashResumeTests).
/// `resumeReader` reads for the second executor and its preflight sync (a lagging App Store Connect).
private func crashAndResume(_ h: ExecutorHarness, planId: String, at crash: ExecutorStep,
                            policy: PolicyEngine = PolicyEngine(planRules: [], invariants: []),
                            resumeReader: (any ASCReading)? = nil) async throws -> PlanState {
    let first = h.makeExecutor(policy: policy)
    await first.setStepHook { step in if step == crash { throw SimulatedCrash() } }
    do {
        _ = try await first.apply(planId: planId, confirm: Confirm.accept)
        Issue.record("the simulated crash at \(crash) did not happen")
    } catch is SimulatedCrash {
    }
    h.clock.advance(by: AppleConstants.heartbeatSeconds * 4)
    let second = h.makeExecutor(policy: policy, reader: resumeReader, syncReader: resumeReader)
    #expect(try await second.recover(afterWake: false) == [planId])
    return try await second.resume(planId: planId, confirm: Confirm.accept)
}

/// Exactly one version was created and it holds the planned texts; every item ended Effective.
private func expectOneNewVersionWithTheTexts(_ h: ExecutorHarness, _ planned: NewVersionScenario.Planned, versionsBefore: Int) async throws {
    let model = await h.fake.model
    let versions = model.versions.filter { $0.owner == NewVersionScenario.owner }
    #expect(versions.count == versionsBefore + 1)
    let created = try #require(versions.max { $0.number < $1.number })
    var texts: [String: LocalizationText] = [:]
    for row in model.localizations where row.versionId == created.id { texts[row.locale] = row.text }
    #expect(texts["en-US"]?.name == NewVersionScenario.newName)
    #expect(texts["de-DE"] == NewVersionScenario.german)
    #expect(await h.fake.writeRequests().filter { $0.path == "/v1/subscriptionVersions" }.count == 1)
    let states = try h.store.items(planId: planned.planId).map(\.state)
    #expect(states.allSatisfy { $0 == .effective })
}

/// The version item is Stale with the replan note and every text of the plan was skipped.
private func expectStaleVersionAndSkippedTexts(_ h: ExecutorHarness, _ planned: NewVersionScenario.Planned) throws {
    let versionSeq = try #require(NewVersionScenario.versionSeq(planned))
    let items = try h.store.items(planId: planned.planId)
    let version = try #require(items.first { $0.item.seq == versionSeq })
    #expect(version.state == .stale)
    #expect(version.ascId == nil)
    #expect(items.filter { $0.item.seq != versionSeq }.allSatisfy { $0.state == .skipped })
    let notes = try h.audit.events(after: 0, limit: 100_000)
        .filter { $0.type == .itemStateChanged && $0.refs["seq"] == String(versionSeq) }.map(\.payloadJSON)
    #expect(notes.contains { $0.contains("the version may already exist") && $0.contains("re-sync and re-plan") })
}

@Suite("Crash and resume: new versions (L3)")
struct NewVersionCrashResumeTests {
    func prepare() async throws -> (ExecutorHarness, NewVersionScenario.Planned, Int) {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        #expect(NewVersionScenario.versionSeq(planned) == 1)
        let before = await h.fake.model.versions.filter { $0.owner == NewVersionScenario.owner }.count
        return (h, planned, before)
    }

    @Test func aCrashBeforeTheVersionPostIsSentOnceOnResume() async throws {
        let (h, planned, before) = try await prepare()
        // .beforeSend: the item is still Pending (no httpSent), so resume sends it like any Pending item.
        #expect(try await crashAndResume(h, planId: planned.planId, at: .beforeSend(seq: 1)) == .effective)
        try await expectOneNewVersionWithTheTexts(h, planned, versionsBefore: before)
    }

    @Test func anAbortWhoseReadDoesNotShowTheCreatedVersionKeepsItStaleAndDoesNotClaimNoWrites() async throws {
        let (h, planned, before) = try await prepare()
        let known = Set(await h.fake.model.versions.map(\.id))
        let first = h.makeExecutor()
        await first.setStepHook { step in if step == .afterResponse(seq: 1) { throw SimulatedCrash() } }
        do {
            _ = try await first.apply(planId: planned.planId, confirm: Confirm.accept)
            Issue.record("the simulated crash did not happen")
        } catch is SimulatedCrash {
        }
        h.clock.advance(by: AppleConstants.heartbeatSeconds * 4)
        let lagging = LaggingVersionReader(inner: h.reader, known: known, lag: 1)
        let second = h.makeExecutor(reader: lagging)
        #expect(try await second.recover(afterWake: false) == [planned.planId])
        #expect(try await second.abort(planId: planned.planId) == .partiallyApplied)
        #expect(try h.store.plan(id: planned.planId)?.endReason == nil)
        let versionSeq = try #require(NewVersionScenario.versionSeq(planned))
        let notes = try h.audit.events(after: 0, limit: 100_000)
            .filter { $0.type == .itemStateChanged && $0.refs["seq"] == String(versionSeq) }.map(\.payloadJSON)
        #expect(notes.contains { $0.contains("abort: the version may already exist") && $0.contains("re-sync and re-plan") })
        let items = try h.store.items(planId: planned.planId)
        #expect(items.first { $0.item.seq == versionSeq }?.state == .stale)
        #expect(items.filter { $0.item.seq != versionSeq }.allSatisfy { $0.state == .skipped })
        #expect(await h.fake.writeRequests().map(\.path) == ["/v1/subscriptionVersions"])
        #expect(await h.fake.model.versions.filter { $0.owner == NewVersionScenario.owner }.count == before + 1)
    }

    /// After httpSent nobody knows whether the POST left. A read without a version cannot prove it did not (it may lag), and
    /// a version cannot be deleted: the version item is Stale, its texts are skipped, nothing is sent (re-sync and replan).
    @Test func aCrashRightAfterHTTPSentNeverSendsTheVersionPost() async throws {
        let (h, planned, before) = try await prepare()
        #expect(try await crashAndResume(h, planId: planned.planId, at: .afterHTTPSent(seq: 1)) == .stale)
        try expectStaleVersionAndSkippedTexts(h, planned)
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(await h.fake.model.versions.filter { $0.owner == NewVersionScenario.owner }.count == before)
    }

    @Test func aResumeWhoseReadDoesNotShowTheCreatedVersionYetMakesItStaleWithoutASecondPost() async throws {
        let (h, planned, before) = try await prepare()
        let known = Set(await h.fake.model.versions.map(\.id))
        let lagging = LaggingVersionReader(inner: h.reader, known: known, lag: 1)
        #expect(try await crashAndResume(h, planId: planned.planId, at: .afterResponse(seq: 1), resumeReader: lagging) == .stale)
        #expect(lagging.readsWithNewVersion.value >= 1)
        try expectStaleVersionAndSkippedTexts(h, planned)
        #expect(await h.fake.writeRequests().map(\.path) == ["/v1/subscriptionVersions"])
        #expect(await h.fake.model.versions.filter { $0.owner == NewVersionScenario.owner }.count == before + 1)
    }

    @Test func aCrashAfterTheVersionWasCreatedFindsItByReading() async throws {
        let (h, planned, before) = try await prepare()
        #expect(try await crashAndResume(h, planId: planned.planId, at: .afterResponse(seq: 1)) == .effective)
        try await expectOneNewVersionWithTheTexts(h, planned, versionsBefore: before)
        let notes = try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .itemStateChanged && $0.refs["seq"] == "1" }.map(\.payloadJSON)
        #expect(notes.contains { $0.contains("preflight 2b: target found") })
    }

    @Test func aCrashBetweenTheVersionAndItsTextsContinuesWithTheTexts() async throws {
        let (h, planned, before) = try await prepare()
        #expect(try await crashAndResume(h, planId: planned.planId, at: .afterItemCommitted(seq: 1)) == .effective)
        try await expectOneNewVersionWithTheTexts(h, planned, versionsBefore: before)
    }

    @Test func theFullPolicyLetsTheTextsContinueAfterTheVersion() async throws {
        let (h, planned, before) = try await prepare()
        #expect(try await crashAndResume(h, planId: planned.planId, at: .afterItemCommitted(seq: 1), policy: PolicyEngine()) == .effective)
        try await expectOneNewVersionWithTheTexts(h, planned, versionsBefore: before)
    }
}
