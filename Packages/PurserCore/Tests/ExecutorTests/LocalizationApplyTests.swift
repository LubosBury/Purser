import Foundation
import Testing
import Domain
import Store
import Audit
import ASCClient
import Catalog
import Policy
import Planner
@testable import Executor
import PurserTestSupport

private struct MissingFixture: Error { let what: String }

private let subN = LocalizationOwner.subscription("sub-n")

/// sub-n has version 1 PREPARE_FOR_SUBMISSION with en-US (FakeSeed): cs is a POST (seq 1), en-US a PATCH (seq 2).
private let subNEdits = [
    LocalizationEdit(owner: subN, locale: "en-US", name: "Fruit Yearly Plus", description: "All fruit for a year"),
    LocalizationEdit(owner: subN, locale: "cs", name: "Ročně nové", description: "Celý rok ovoce"),
]

private func canonical(_ data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data)
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

private func payload(_ event: AuditEvent) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any] else {
        throw MissingFixture(what: "payload of \(event.type)")
    }
    return object
}

/// Plans `edits` with the real Planner (no policy rules) against a fresh sync and stores the Draft.
func storeTextPlan(_ h: ExecutorHarness, _ edits: [LocalizationEdit]) async throws -> (planId: String, draft: PlanDraft) {
    let snapshot = try await h.initialSync()
    let spec = PlanSpec.localization(LocalizationPlanSpec(edits: edits))
    let draft = try Planner(policy: PolicyEngine(planRules: [], invariants: []))
        .plan(spec, context: PlanningContext(snapshot: snapshot, config: h.config, today: h.today))
    let planId = try PlanPersistence(store: h.store, audit: h.audit, appBuild: "test")
        .saveDraft(draft, binding: PlanBinding(config: h.config), reason: nil, replanOf: nil)
    return (planId, draft)
}

func subNTextEdits() -> [LocalizationEdit] { subNEdits }

/// sub-n's version 1 (the plan's PATCH and POST target) is approved now, and version 2 in preparation holds a copy of its texts.
private func approveVersionAndCopyItsTexts(_ h: ExecutorHarness) async {
    await h.fake.mutate { model in
        for index in model.versions.indices where model.versions[index].id == "ver-sub-n-1" { model.versions[index].state = .approved }
        model.versions.append(FakeVersion(id: "ver-sub-n-2", owner: subN, number: 2, state: .prepareForSubmission))
        model.localizations += model.localizations.filter { $0.versionId == "ver-sub-n-1" }.map {
            FakeLocalization(id: "loc-sub-n-2-\($0.locale)", versionId: "ver-sub-n-2", locale: $0.locale, text: $0.text)
        }
    }
}

private func items(_ h: ExecutorHarness, _ planId: String) throws -> [StoredItem] {
    try h.store.items(planId: planId).sorted { $0.item.seq < $1.item.seq }
}

@Suite("Executor localization")
struct LocalizationApplyTests {
    @Test func aPatchAndAPostIntoTheEditableVersionEndEffective() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, draft) = try await storeTextPlan(h, subNEdits)
        #expect(draft.items.map(\.op) == [.setText, .setText])
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .effective)
        let stored = try items(h, planId)
        #expect(stored.map(\.state) == [.effective, .effective])
        #expect(stored.allSatisfy { $0.verifiedAt != nil })
        guard case let .setLocalization(patch) = stored[1].item.payload, let patchedId = patch.localizationId else {
            Issue.record("the second item is not a PATCH"); return
        }
        #expect(stored[1].ascId == patchedId)
        let writes = await h.fake.writeRequests()
        #expect(writes.map { "\($0.method) \($0.path)" } == ["POST /v2/subscriptionLocalizations", "PATCH /v2/subscriptionLocalizations/\(patchedId)"])
        // httpSent carries the real method, path and body of every write.
        let sent = try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .httpSent }
        #expect(sent.count == 2)
        for (event, request) in zip(sent, writes) {
            let audited = try payload(event)
            #expect(audited["method"] as? String == request.method)
            #expect(audited["path"] as? String == request.path)
            #expect(audited["op"] as? String == "SET_TEXT")
            #expect(try canonical(Data((audited["body"] as? String ?? "").utf8)) == canonical(request.body ?? Data()))
        }
        let model = await h.fake.model
        let version = try #require(model.versions.first { $0.owner == subN && $0.state.role == .editable })
        let rows = model.localizations.filter { $0.versionId == version.id }
        #expect(Set(rows.map(\.locale)) == ["cs", "en-US"])
        // The POST's asc_id is the id of the localization it created.
        let posted = try #require(rows.first { $0.locale == "cs" })
        #expect(stored[0].ascId == posted.id)
        #expect(rows.first { $0.locale == "en-US" }?.text.name == "Fruit Yearly Plus")
        #expect(rows.first { $0.locale == "cs" }?.text.description == "Celý rok ovoce")
        // Texts Purser wrote are PURSER, not EXTERNAL.
        #expect(try h.catalog.findings(includeAcked: false).filter { $0.cell.productAscId == "sub-n" }.isEmpty)
    }

    @Test func verifyReadsTheOwnerAgainAfterTheWrites() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await storeTextPlan(h, subNEdits)
        _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        let requests = await h.fake.requests()
        let lastWrite = try #require(requests.lastIndex { $0.isWrite })
        #expect(requests[(lastWrite + 1)...].contains { $0.method == "GET" && $0.path == "/v1/subscriptions/sub-n/versions" })
        let verify = try #require(try h.audit.events(after: 0, limit: 100_000).last { $0.type == .verify })
        #expect(verify.refs["product"] == "sub-n")
        #expect(try payload(verify)["verified"] as? [Int] == [1, 2])
    }

    @Test func a409FailsTheTextWithoutARetry() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await storeTextPlan(h, subNEdits)
        await h.fake.inject(.conflict(code: "ENTITY_ERROR.STATE_INVALID", detail: "Synthetic refusal"), times: 1, matching: .method("POST"))
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .partiallyApplied)
        #expect(try items(h, planId).map(\.state) == [.failed, .effective])
        let writes = await h.fake.writeRequests()
        #expect(writes.filter { $0.method == "POST" }.count == 1)
        let received = try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .httpReceived }
        let refused = try payload(try #require(received.first))
        #expect(refused["method"] as? String == "POST")
        #expect(refused["path"] as? String == "/v2/subscriptionLocalizations")
        #expect(refused["status"] as? Int == 409)
    }

    @Test func aPausedTextPlanResumesAfterItsVersionWasMarkedReadyForReview() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await storeTextPlan(h, subNEdits)
        try h.updatePlan(planId) { $0.state = .applying; $0.pauseReason = .user }
        // PREPARE_FOR_SUBMISSION -> READY_FOR_REVIEW: the version stays editable, so rule A4 lets the resume through.
        await h.fake.mutate { model in
            for index in model.versions.indices where model.versions[index].owner == subN { model.versions[index].state = .readyForReview }
        }
        #expect(try await h.makeExecutor(policy: PolicyEngine()).resume(planId: planId, confirm: Confirm.accept) == .effective)
        #expect(try items(h, planId).map(\.state) == [.effective, .effective])
    }

    @Test func aResumeAfterTheVersionWasApprovedAndANewOneCopiedItsTextsWritesNothing() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await storeTextPlan(h, subNEdits)
        try h.updatePlan(planId) { $0.state = .applying; $0.pauseReason = .user }
        await approveVersionAndCopyItsTexts(h)
        await #expect(throws: ExecutorError.blocked(["A4"])) {
            try await h.makeExecutor(policy: PolicyEngine()).resume(planId: planId, confirm: Confirm.accept)
        }
        #expect(try items(h, planId).map(\.state) == [.stale, .stale])
        let plan = try #require(try h.store.plan(id: planId))
        #expect(plan.state == .applying && plan.pauseReason == .user)
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(try h.audit.events(after: 0, limit: 100_000).allSatisfy { $0.type != .httpSent })
    }

    @Test func withoutRuleA4TheReconcilerStillStopsATextForAVersionThatWasApproved() async throws {
        let h = try await ExecutorHarness.make()
        let (applied, _) = try await storeTextPlan(h, subNEdits)
        let (resumed, _) = try await storeTextPlan(h, subNEdits)
        await approveVersionAndCopyItsTexts(h)
        #expect(try await h.makeExecutor().apply(planId: applied, confirm: Confirm.accept) == .stale)
        try h.updatePlan(resumed) { $0.state = .applying; $0.pauseReason = .user }
        _ = try await h.makeExecutor().resume(planId: resumed, confirm: Confirm.accept)
        #expect(try items(h, resumed).map(\.state) == [.stale, .stale])
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func aGroupOwnerGoesThroughPreflightAndVerify() async throws {
        let h = try await ExecutorHarness.make()
        let group = LocalizationOwner.group("grp-1")
        // The seed's group version is approved; this test needs one in preparation.
        await h.fake.mutate { model in
            for index in model.versions.indices where model.versions[index].owner == group { model.versions[index].state = .prepareForSubmission }
        }
        let (planId, draft) = try await storeTextPlan(h, [LocalizationEdit(owner: group, locale: "en-US", customAppName: "FruitJar Premium")])
        #expect(draft.items.count == 1)
        #expect(try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept) == .effective)
        let writes = await h.fake.writeRequests()
        #expect(writes.map(\.method) == ["PATCH"])
        #expect(writes.first?.path.hasPrefix("/v2/subscriptionGroupLocalizations/") == true)
        let model = await h.fake.model
        #expect(model.localizations.first { $0.text.customAppName == "FruitJar Premium" }?.locale == "en-US")
        let verify = try #require(try h.audit.events(after: 0, limit: 100_000).last { $0.type == .verify })
        #expect(verify.refs["product"] == "grp-1")
    }

    @Test func aTextWithoutIdsAndWithoutACreatedVersionGoesStaleUnsent() async throws {
        let h = try await ExecutorHarness.make()
        let snapshot = try await h.initialSync()
        let cell = CellKey.localization(owner: subN, locale: "cs")
        let before = snapshot.cellState(cell, on: h.today)
        let item = PlannedItem(seq: 1, cell: cell,
                               payload: .setLocalization(SetLocalization(owner: subN, locale: "cs", text: LocalizationText(name: "Ročně"),
                                                                         localizationId: nil, versionId: nil)),
                               before: before, target: before)
        let planId = try h.insertPlan(items: [item], origin: .localization)
        _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        #expect(try items(h, planId).map(\.state) == [.stale])
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(try h.audit.events(after: 0, limit: 100_000).allSatisfy { $0.type != .httpSent })
    }
}
