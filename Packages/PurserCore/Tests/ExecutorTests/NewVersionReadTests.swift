import Foundation
import Testing
import Domain
import Store
import Audit
import ASCClient
@testable import Executor
import PurserTestSupport

private let owner = NewVersionScenario.owner
private let ownerVersionsPath = "/v1/subscriptions/sub-y/versions"

/// Injects `fault` into the next read of the owner's versions once Purser's version POST has succeeded, so only the read
/// before the texts fails.
private struct FaultAfterVersionWriter: ASCWriting {
    let inner: any ASCWriting
    let fake: FakeASC
    let fault: FakeFault
    func createMetadataVersion(owner: LocalizationOwner) async throws -> MetadataVersion {
        let created = try await inner.createMetadataVersion(owner: owner)
        await fake.inject(fault, times: 1, matching: .pathPrefix(ownerVersionsPath))
        return created
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

private func isText(_ item: PlannedItem) -> Bool {
    if case .setLocalization = item.payload { return true }
    return false
}

private func textWrites(_ requests: [FakeRequestRecord]) -> [FakeRequestRecord] {
    requests.filter { $0.isWrite && $0.path.hasPrefix("/v2/subscriptionLocalizations") }
}

private func pauses(_ h: ExecutorHarness, _ reason: PauseReason) throws -> Int {
    try h.audit.events(after: 0, limit: 100_000)
        .filter { $0.type == .planStateChanged && $0.payloadJSON.contains("\"pause\":\"\(reason.rawValue)\"") }.count
}

/// The read of the owner before the texts of a version the plan created (L3).
@Suite("Executor: reading a created version before its texts (L3)")
struct NewVersionReadTests {
    @Test func theTextsOfOneOwnerShareOneReadOfTheCreatedVersion() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        let withoutIds = planned.draft.items.filter {
            if case let .setLocalization(s) = $0.payload { return s.localizationId == nil && s.versionId == nil }
            return false
        }
        #expect(withoutIds.count >= 2)
        #expect(try await h.makeExecutor().apply(planId: planned.planId, confirm: Confirm.accept) == .effective)
        let requests = await h.fake.requests()
        let post = try #require(requests.firstIndex { $0.method == "POST" && $0.path == "/v1/subscriptionVersions" })
        let lastWrite = try #require(requests.lastIndex { $0.isWrite })
        #expect(requests[post...lastWrite].filter { $0.method == "GET" && $0.path == ownerVersionsPath }.count == 1)
    }

    @Test(arguments: zip([FakeFault.rateLimited, .serverError(status: 500, applyFirst: false)], [PauseReason.rate, .network]))
    func aFailedReadBeforeTheTextsWaitsAndReadsAgain(fault: FakeFault, reason: PauseReason) async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        let writer = FaultAfterVersionWriter(inner: h.writer, fake: h.fake, fault: fault)
        #expect(try await h.makeExecutor(writer: writer).apply(planId: planned.planId, confirm: Confirm.accept) == .effective)
        #expect(try pauses(h, reason) >= 1)

        // In ASC: the failed read, then a read that succeeds, and only then the texts.
        let requests = await h.fake.requests()
        let post = try #require(requests.firstIndex { $0.method == "POST" && $0.path == "/v1/subscriptionVersions" })
        let reads = requests[post...].filter { $0.method == "GET" && $0.path == ownerVersionsPath }
        let failed = try #require(reads.first)
        #expect(failed.status == (reason == .rate ? 429 : 500))
        let succeeded = try #require(reads.dropFirst().first)
        #expect(succeeded.status == 200)
        let texts = textWrites(requests)
        #expect(texts.count == 2)
        #expect(texts.allSatisfy { $0.index > succeeded.index })

        // In the audit: no httpSent of a text before the automatic resume, and every text was sent once.
        let events = try h.audit.events(after: 0, limit: 100_000)
        let resumed = try #require(events.lastIndex { $0.type == .planStateChanged && $0.payloadJSON.contains("automatic resume after") })
        let textSeqs = Set(planned.draft.items.filter(isText).map { String($0.seq) })
        let sentTexts = events.indices.filter { events[$0].type == .httpSent && textSeqs.contains(events[$0].refs["seq"] ?? "") }
        #expect(sentTexts.count == 2)
        #expect(sentTexts.allSatisfy { $0 > resumed })
        #expect(try h.store.items(planId: planned.planId).filter { isText($0.item) }.allSatisfy { $0.attempts <= 1 })
    }

    @Test(arguments: [FakeFault.timeoutAfterApply, .serverError(status: 500, applyFirst: true)])
    func anUncertainAnswerToTheVersionPostIsConfirmedByReadingNeverByASecondPost(fault: FakeFault) async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        let versionSeq = try #require(NewVersionScenario.versionSeq(planned))
        let known = Set(await h.fake.model.versions.map(\.id))
        // The version is created, the answer is lost (or a 5xx) and the next two reads do not show the version yet.
        await h.fake.inject(fault, times: 1, matching: .pathPrefix("/v1/subscriptionVersions"))
        let reader = LaggingVersionReader(inner: h.reader, known: known, lag: 2)
        #expect(try await h.makeExecutor(reader: reader).apply(planId: planned.planId, confirm: Confirm.accept) == .effective)
        #expect(await h.fake.writeRequests().filter { $0.path == "/v1/subscriptionVersions" }.count == 1)
        #expect(try pauses(h, .network) >= 2)

        let model = await h.fake.model
        let created = try #require(model.versions.filter { $0.owner == owner }.max { $0.number < $1.number })
        #expect(!known.contains(created.id))
        let items = try h.store.items(planId: planned.planId)
        #expect(items.first { $0.item.seq == versionSeq }?.ascId == created.id)
        #expect(items.allSatisfy { $0.state == .effective })
        var texts: [String: LocalizationText] = [:]
        for row in model.localizations where row.versionId == created.id { texts[row.locale] = row.text }
        #expect(texts["en-US"]?.name == NewVersionScenario.newName)
        #expect(texts["de-DE"] == NewVersionScenario.german)
        let notes = try h.audit.events(after: 0, limit: 100_000)
            .filter { $0.type == .itemStateChanged && $0.refs["seq"] == String(versionSeq) }.map(\.payloadJSON)
        #expect(notes.contains { $0.contains("fresh read found the version") })
    }

    @Test func whenTheWaitsRunOutThePlanPausesAndTheVersionIsNotSentAgain() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        let versionSeq = try #require(NewVersionScenario.versionSeq(planned))
        let known = Set(await h.fake.model.versions.map(\.id))
        await h.fake.inject(.timeoutAfterApply, times: 1, matching: .pathPrefix("/v1/subscriptionVersions"))
        let reader = LaggingVersionReader(inner: h.reader, known: known, lag: 1_000)
        #expect(try await h.makeExecutor(reader: reader).apply(planId: planned.planId, confirm: Confirm.accept) == .applying)
        #expect(try h.store.plan(id: planned.planId)?.pauseReason == .network)
        #expect(try h.store.items(planId: planned.planId).first { $0.item.seq == versionSeq }?.state == .inFlight)
        #expect(await h.fake.writeRequests().map(\.path) == ["/v1/subscriptionVersions"])

        // Resume (Touch ID) with a read that shows the version: it is found, never posted again, and the texts follow.
        #expect(try await h.makeExecutor().resume(planId: planned.planId, confirm: Confirm.accept) == .effective)
        #expect(await h.fake.writeRequests().filter { $0.path == "/v1/subscriptionVersions" }.count == 1)
        #expect(try h.store.items(planId: planned.planId).allSatisfy { $0.state == .effective })
    }

    @Test func aCreatedVersionTheReadDoesNotShowYetIsReadAgainBeforeAnyText() async throws {
        let h = try await ExecutorHarness.make()
        await h.fake.setNewVersionCopiesLocalizations(true)
        let planned = try await NewVersionScenario.plan(h)
        let known = Set(await h.fake.model.versions.map(\.id))
        let reader = LaggingVersionReader(inner: h.reader, known: known, lag: 1)
        #expect(try await h.makeExecutor(reader: reader).apply(planId: planned.planId, confirm: Confirm.accept) == .effective)
        // The read without the version was not kept: one more read, then the run's cached read serves every text.
        #expect(reader.readsWithNewVersion.value == 2)
        #expect(try pauses(h, .network) >= 1)

        // Copied locales were never POSTed into the version: en-US is a PATCH of its copy, cs needed no write.
        let writes = await h.fake.writeRequests().map { "\($0.method) \($0.path)" }
        #expect(writes.count == 3)
        #expect(writes.filter { $0 == "POST /v2/subscriptionLocalizations" }.count == 1)
        #expect(writes.filter { $0.hasPrefix("PATCH /v2/subscriptionLocalizations/") }.count == 1)
        let model = await h.fake.model
        let created = try #require(model.versions.filter { $0.owner == owner }.max { $0.number < $1.number })
        let locales = model.localizations.filter { $0.versionId == created.id }.map(\.locale)
        #expect(locales.sorted() == ["cs", "de-DE", "en-US"])
        #expect(try h.store.items(planId: planned.planId).allSatisfy { $0.state == .effective })
    }
}
