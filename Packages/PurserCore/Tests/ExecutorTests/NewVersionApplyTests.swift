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

private let owner = NewVersionScenario.owner

private func writes(_ h: ExecutorHarness) async -> [String] {
    await h.fake.writeRequests().map { "\($0.method) \($0.path)" }
}

/// The notes of the version item's state changes.
private func versionNotes(_ h: ExecutorHarness, seq: Int) throws -> [String] {
    try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .itemStateChanged && $0.refs["seq"] == String(seq) }
        .compactMap { (try JSONSerialization.jsonObject(with: Data($0.payloadJSON.utf8)) as? [String: Any])?["note"] as? String }
}

private func versionCount(_ h: ExecutorHarness) async -> Int {
    await h.fake.model.versions.filter { $0.owner == owner }.count
}

/// Puts an editable version that Purser did not create on the owner right before Purser's POST: FakeASC refuses the POST
/// with 409 (spec §7).
private struct ForeignVersionFirstWriter: ASCWriting {
    let inner: any ASCWriting
    let fake: FakeASC
    func createMetadataVersion(owner: LocalizationOwner) async throws -> MetadataVersion {
        let model = await fake.model
        let number = (model.versions.filter { $0.owner == owner }.map(\.number).max() ?? 0) + 1
        await fake.mutate { $0.versions.append(FakeVersion(id: "sv-foreign", owner: owner, number: number, state: .prepareForSubmission)) }
        return try await inner.createMetadataVersion(owner: owner)
    }
    func createRegularPrice(_ r: NewRegularPrice) async throws -> RegularPriceRow { try await inner.createRegularPrice(r) }
    func deleteRegularPrice(ascId: String) async throws { try await inner.deleteRegularPrice(ascId: ascId) }
    func createIntroductoryOffer(_ r: NewIntroOffer) async throws -> IntroOfferRow { try await inner.createIntroductoryOffer(r) }
    func endIntroductoryOffer(ascId: String, endDate: CalendarDate) async throws { try await inner.endIntroductoryOffer(ascId: ascId, endDate: endDate) }
    func deleteIntroductoryOffer(ascId: String) async throws { try await inner.deleteIntroductoryOffer(ascId: ascId) }
    func createPromotionalOffer(_ r: NewPromoOffer) async throws -> PromoOffer { try await inner.createPromotionalOffer(r) }
    func replacePromotionalOfferPrices(ascId: String, prices: [NewPromoPrice]) async throws { try await inner.replacePromotionalOfferPrices(ascId: ascId, prices: prices) }
    func deletePromotionalOffer(ascId: String) async throws { try await inner.deletePromotionalOffer(ascId: ascId) }
    func replaceIAPPriceSchedule(_ r: NewIAPSchedule) async throws { try await inner.replaceIAPPriceSchedule(r) }
    func createLocalization(versionId: String, owner: LocalizationOwner, locale: String, text: LocalizationText) async throws -> LocalizationRow {
        try await inner.createLocalization(versionId: versionId, owner: owner, locale: locale, text: text)
    }
    func updateLocalization(localizationId: String, owner: LocalizationOwner, text: LocalizationText) async throws {
        try await inner.updateLocalization(localizationId: localizationId, owner: owner, text: text)
    }
}

@Suite("Executor: new versions of approved products (L3)")
struct NewVersionApplyTests {
    @Test func appliesANewVersionOfAnApprovedSubscription() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        #expect(planned.draft.verdicts.allSatisfy { if case .block = $0.severity { return false } else { return true } })
        let versionsBefore = await versionCount(h)
        let levels = Locked<[ConfirmationLevel]>([])
        let state = try await h.makeExecutor(policy: PolicyEngine()).apply(planId: planned.planId) { request in
            levels.update { $0.append(request.level) }
            return await Confirm.accept(request)
        }
        #expect(state == .effective)
        #expect(levels.value == [.c1])
        let items = try h.store.items(planId: planned.planId)
        #expect(items.allSatisfy { $0.state == .effective && $0.verifiedAt != nil })

        let model = await h.fake.model
        let versions = model.versions.filter { $0.owner == owner }.sorted { $0.number < $1.number }
        #expect(versions.count == versionsBefore + 1)
        let created = try #require(versions.last)
        #expect(created.number == planned.live.number + 1)
        #expect(created.state == .prepareForSubmission)
        #expect(items.first { $0.item.seq == NewVersionScenario.versionSeq(planned) }?.ascId == created.id)
        var texts: [String: LocalizationText] = [:]
        for row in model.localizations where row.versionId == created.id { texts[row.locale] = row.text }
        let english = try #require(planned.liveTexts["en-US"])
        #expect(texts["en-US"] == LocalizationText(name: NewVersionScenario.newName, description: english.description))
        #expect(texts["de-DE"] == NewVersionScenario.german)
        #expect(texts["cs"] == planned.liveTexts["cs"])
        var liveNow: [String: LocalizationText] = [:]
        for row in model.localizations where row.versionId == planned.live.ascId { liveNow[row.locale] = row.text }
        #expect(liveNow == planned.liveTexts)

        let copiedEnglish = try #require(model.localizations.first { $0.versionId == created.id && $0.locale == "en-US" })
        let sent = await writes(h)
        #expect(sent.count == 3)
        #expect(sent.contains("POST /v1/subscriptionVersions"))
        #expect(sent.contains("PATCH /v2/subscriptionLocalizations/\(copiedEnglish.id)"))
        #expect(sent.contains("POST /v2/subscriptionLocalizations"))
        #expect(try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .httpSent }.count == 3)
        // Copied and written texts in a version Purser created are PURSER, not EXTERNAL.
        #expect(try h.catalog.findings(includeAcked: false).filter { $0.type == .external && $0.cell.localizationOwner == owner }.isEmpty)
    }

    @Test func aLostAnswerToTheVersionPostIsResolvedByReading() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        let versionsBefore = await versionCount(h)
        await h.fake.inject(.timeoutAfterApply, times: 1, matching: .pathPrefix("/v1/subscriptionVersions"))
        #expect(try await h.makeExecutor().apply(planId: planned.planId, confirm: Confirm.accept) == .effective)
        #expect(await writes(h).filter { $0 == "POST /v1/subscriptionVersions" }.count == 1)
        #expect(await versionCount(h) == versionsBefore + 1)
    }

    @Test func a409OnTheVersionMakesItStaleAndSkipsItsTexts() async throws {
        let h = try await ExecutorHarness.make()
        let planned = try await NewVersionScenario.plan(h)
        let versionSeq = try #require(NewVersionScenario.versionSeq(planned))
        await h.fake.inject(.conflict(code: "ENTITY_ERROR.STATE_INVALID", detail: "A version that is not approved already exists"),
                            times: 1, matching: .pathPrefix("/v1/subscriptionVersions"))
        #expect(try await h.makeExecutor().apply(planId: planned.planId, confirm: Confirm.accept) == .stale)
        let items = try h.store.items(planId: planned.planId)
        let version = try #require(items.first { $0.item.seq == versionSeq })
        #expect(version.state == .stale)
        #expect(version.errorJSON != nil)
        #expect(items.filter { $0.item.seq != versionSeq }.allSatisfy { $0.state == .skipped })
        #expect(await writes(h) == ["POST /v1/subscriptionVersions"])
        let received = try h.audit.events(after: 0, limit: 100_000).filter { $0.type == .httpReceived }
        #expect(received.count == 1)
        // The audit JSON escapes "/", so the route is read from the decoded payload.
        let event = try #require(received.first)
        let refused = try #require(try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any])
        #expect(refused["status"] as? Int == 409)
        #expect(refused["method"] as? String == "POST")
        #expect(refused["path"] as? String == "/v1/subscriptionVersions")
        #expect(try versionNotes(h, seq: versionSeq).contains("409: App Store Connect refused the new version; the owner may already have a pending version. Re-plan."))
    }

    @Test func anotherRefusalOfTheVersionNamesItsStatusAndNoPendingVersion() async throws {
        let h = try await ExecutorHarness.make()
        let planned = try await NewVersionScenario.plan(h)
        let versionSeq = try #require(NewVersionScenario.versionSeq(planned))
        await h.fake.inject(.serverError(status: 422, applyFirst: false), times: 1, matching: .pathPrefix("/v1/subscriptionVersions"))
        #expect(try await h.makeExecutor().apply(planId: planned.planId, confirm: Confirm.accept) == .stale)
        let notes = try versionNotes(h, seq: versionSeq)
        #expect(notes.contains("422: App Store Connect refused the new version. Re-plan."))
        #expect(!notes.contains { $0.contains("pending version") })
        #expect(await writes(h) == ["POST /v1/subscriptionVersions"])
    }

    @Test func aVersionSomeoneElseCreatedIsNotAdopted() async throws {
        let h = try await ExecutorHarness.make()
        let planned = try await NewVersionScenario.plan(h)
        let versionSeq = try #require(NewVersionScenario.versionSeq(planned))
        let versionsBefore = await versionCount(h)
        let writer = ForeignVersionFirstWriter(inner: h.writer, fake: h.fake)
        #expect(try await h.makeExecutor(writer: writer).apply(planId: planned.planId, confirm: Confirm.accept) == .stale)
        let items = try h.store.items(planId: planned.planId)
        #expect(items.first { $0.item.seq == versionSeq }?.state == .stale)
        // The foreign version's id is never recorded, so no text could ever be resolved into it.
        #expect(items.first { $0.item.seq == versionSeq }?.ascId == nil)
        #expect(Executor.createdVersions(in: Dictionary(uniqueKeysWithValues: items.map { ($0.item.seq, $0) })).isEmpty)
        #expect(items.filter { $0.item.seq != versionSeq }.allSatisfy { $0.state == .skipped })
        #expect(await writes(h) == ["POST /v1/subscriptionVersions"])
        let versions = await h.fake.model.versions.filter { $0.owner == owner }
        #expect(versions.count == versionsBefore + 1)
        #expect(versions.contains { $0.id == "sv-foreign" })
    }

    @Test func aVersionInReviewBlocksTheApplyAtPreflight() async throws {
        let h = try await ExecutorHarness.make()
        let planned = try await NewVersionScenario.plan(h)
        let next = planned.live.number + 1
        await h.fake.mutate { $0.versions.append(FakeVersion(id: "sv-review", owner: owner, number: next, state: .waitingForReview)) }
        #expect(try await h.makeExecutor(policy: PolicyEngine()).apply(planId: planned.planId, confirm: Confirm.accept) == .stale)
        let plan = try #require(try h.store.plan(id: planned.planId))
        #expect(plan.verdicts.contains { $0.rule == "N1" && $0.severity == .block(.cell) && $0.cell == .metadataVersion(owner: owner) })
        let states = try h.store.items(planId: planned.planId).map(\.state)
        #expect(states.allSatisfy { $0 == .stale || $0 == .skipped })
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test(.enabled(if: !AppleConstants.newVersionCopiesLocalizations, "while copying is unconfirmed the version gets every Live text"))
    func withoutACopyEveryTextIsPostedIntoTheNewVersion() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(false)
        let planned = try await NewVersionScenario.plan(h)
        #expect(try await h.makeExecutor().apply(planId: planned.planId, confirm: Confirm.accept) == .effective)
        let model = await h.fake.model
        let created = try #require(model.versions.filter { $0.owner == owner }.max { $0.number < $1.number })
        var texts: [String: LocalizationText] = [:]
        for row in model.localizations where row.versionId == created.id { texts[row.locale] = row.text }
        var expected = planned.liveTexts
        expected["en-US"]?.name = NewVersionScenario.newName
        expected["de-DE"] = NewVersionScenario.german
        #expect(texts == expected)
        let sent = await writes(h)
        #expect(sent.filter { $0 == "POST /v2/subscriptionLocalizations" }.count == expected.count)
        #expect(!sent.contains { $0.hasPrefix("PATCH ") })
    }

    @Test(.enabled(if: AppleConstants.newVersionCopiesLocalizations, "once a live trial confirmed copying, a missing copy is a change"))
    func onceCopyingIsConfirmedAMissingCopyMakesTheTextStale() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(false)
        let planned = try await NewVersionScenario.plan(h)
        #expect(try await h.makeExecutor().apply(planId: planned.planId, confirm: Confirm.accept) == .partiallyApplied)
        let items = try h.store.items(planId: planned.planId)
        let english = try #require(NewVersionScenario.seq(planned, locale: "en-US"))
        let german = try #require(NewVersionScenario.seq(planned, locale: "de-DE"))
        #expect(items.first { $0.item.seq == english }?.state == .stale)
        #expect(items.first { $0.item.seq == german }?.state == .effective)
    }
}
