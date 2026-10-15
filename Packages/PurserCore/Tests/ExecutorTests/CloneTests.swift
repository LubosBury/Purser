import Foundation
import Synchronization
import Testing
import ASCClient
import Audit
import Catalog
import Domain
import Executor
import PurserSecurity
import PurserTestSupport

private final class CountingGate: BiometricGate, Sendable {
    private let asked = Mutex<[String]>([])
    var prompts: Int { asked.withLock { $0.count } }
    var reasons: [String] { asked.withLock { $0 } }
    func authenticate(reason: String) async throws { asked.withLock { $0.append(reason) } }
}

/// Runs `action` when the run asks for Touch ID, after everything was read and before the first write.
private struct ActionGate: BiometricGate {
    let action: @Sendable () async -> Void
    func authenticate(reason: String) async throws { await action() }
}

/// Touch ID that the owner refuses.
private struct RefusingGate: BiometricGate {
    func authenticate(reason: String) async throws { throw BiometricError.notAuthenticated }
}

/// Reports the review screenshots in `screenshots` for their owners; every other read goes to `inner`.
private struct SwappedScreenshotReader: ASCReading {
    let inner: any ASCReading
    let screenshots: [LocalizationOwner: ReviewScreenshot]

    func reviewScreenshot(of owner: LocalizationOwner) async throws -> ReviewScreenshot? {
        if let swapped = screenshots[owner] { return swapped }
        return try await inner.reviewScreenshot(of: owner)
    }

    func app(id: String) async throws -> ASCApp { try await inner.app(id: id) }
    func territories() async throws -> [ASCTerritory] { try await inner.territories() }
    func subscriptionGroups(appId: String) async throws -> [ASCSubscriptionGroup] { try await inner.subscriptionGroups(appId: appId) }
    func subscriptions(group: ASCSubscriptionGroup) async throws -> [SubscriptionInfo] { try await inner.subscriptions(group: group) }
    func regularPrices(subscription: SubscriptionInfo) async throws -> [RegularPriceRow] { try await inner.regularPrices(subscription: subscription) }
    func introductoryOffers(subscription: SubscriptionInfo) async throws -> [IntroOfferRow] { try await inner.introductoryOffers(subscription: subscription) }
    func promotionalOffers(subscription: SubscriptionInfo) async throws -> [PromoOffer] { try await inner.promotionalOffers(subscription: subscription) }
    func pricePoints(subscriptionId: String, territories: [TerritoryCode], planType: PlanType?) async throws -> [PricePoint] {
        try await inner.pricePoints(subscriptionId: subscriptionId, territories: territories, planType: planType)
    }
    func inAppPurchases(appId: String) async throws -> [IAPInfo] { try await inner.inAppPurchases(appId: appId) }
    func iapPriceSchedule(iapId: String) async throws -> IAPSchedule? { try await inner.iapPriceSchedule(iapId: iapId) }
    func iapPricePoints(iapId: String, territories: [TerritoryCode]) async throws -> [PricePoint] {
        try await inner.iapPricePoints(iapId: iapId, territories: territories)
    }
    func subscriptionAvailability(subscriptionId: String) async throws -> ProductAvailability? {
        try await inner.subscriptionAvailability(subscriptionId: subscriptionId)
    }
    func iapAvailability(iapId: String) async throws -> ProductAvailability? { try await inner.iapAvailability(iapId: iapId) }
    func metadata(owner: LocalizationOwner) async throws -> OwnerMetadata { try await inner.metadata(owner: owner) }
}

/// Clones of SpikeYearlyA (sub-spike-a) and PurserSpikeLifetime (iap-spike) over FakeASC (FakeSeed.cloneSource).
@Suite("Cloning over FakeASC")
struct CloneTests {
    static let yearly = CloneItem(source: .subscription("sub-spike-a"), productId: "SpikeYearlyA_AB3", name: "SpikeYearlyA_AB3")
    static let lifetime = CloneItem(source: .iap("iap-spike"), productId: "PurserSpikeLifetime_AB3", name: "PurserSpikeLifetime_AB3")

    static func request(_ items: [CloneItem] = [yearly, lifetime], group: CloneGroupTarget = .sourceGroup,
                        level: CloneLevel = .sameAsSource, copy: CloneCopy = CloneCopy()) -> CloneRequest {
        CloneRequest(items: items, group: group, level: level, copy: copy, offerCodeSuffix: "_AB3")
    }

    private struct Run {
        let h: ExecutorHarness
        let snapshot: CatalogSnapshot
        let gate = CountingGate()
        func creator(copiesImages: Bool = true) async throws -> ProductCreator {
            try await h.makeProductCreator(gate: gate, copiesImages: copiesImages)
        }
    }

    private func start() async throws -> Run {
        let h = try await ExecutorHarness.make(model: FakeSeed.cloneSource())
        await h.fake.setUploadPartSize(40)       // the 70-byte sample PNG goes up in two parts
        return Run(h: h, snapshot: try await h.initialSync())
    }

    private static func allCreated(_ report: CloneReport) -> Bool {
        report.steps.allSatisfy { if case .created = $0.outcome { return true } else { return false } }
    }

    private static func isSkipped(_ entry: CloneStepReport) -> Bool {
        if case .skipped = entry.outcome { return true } else { return false }
    }

    @Test func previewListsTheStepsInOrderAndWritesNothing() async throws {
        let run = try await start()
        let preview = try await run.creator().previewClone(Self.request(), snapshot: run.snapshot)
        #expect(preview.blocked.isEmpty)
        let steps = preview.steps
        #expect(steps == [
            .product(Self.yearly), .availability(productId: "SpikeYearlyA_AB3"),
            .localization(productId: "SpikeYearlyA_AB3", locale: "cs"), .localization(productId: "SpikeYearlyA_AB3", locale: "en-US"),
            .reviewScreenshot(productId: "SpikeYearlyA_AB3"),
            .product(Self.lifetime), .availability(productId: "PurserSpikeLifetime_AB3"),
            .localization(productId: "PurserSpikeLifetime_AB3", locale: "en-US"), .reviewScreenshot(productId: "PurserSpikeLifetime_AB3"),
        ])
        #expect(await run.h.fake.writeRequests().isEmpty)
        #expect(run.gate.prompts == 0)
    }

    @Test func aCloneCopiesAttributesAvailabilityTextsAndScreenshotWithOneTouchID() async throws {
        let run = try await start()
        let report = try await run.creator().clone(Self.request(), snapshot: run.snapshot)
        #expect(report.steps.count == 9)
        #expect(Self.allCreated(report))
        #expect(run.gate.reasons == ["clone products in App Store Connect: 9 steps to write (a Product ID can never be used again)"])
        let model = await run.h.fake.model
        let sub = try #require(model.subscriptions.first { $0.productId == "SpikeYearlyA_AB3" })
        #expect(report.created["sub-spike-a"] == sub.id)
        #expect(sub.groupId == "grp-spike" && sub.groupLevel == 1 && sub.period == .oneYear && sub.name == "SpikeYearlyA_AB3")
        #expect(sub.familySharable && sub.reviewNote == "Synthetic review note for the yearly plan")
        #expect(sub.availableTerritories == Set(model.territories.keys) && model.availabilityInNew[sub.id] == true)
        let version = try #require(model.versions.first { $0.owner == .subscription(sub.id) })
        let texts = Dictionary(uniqueKeysWithValues: model.localizations.filter { $0.versionId == version.id }.map { ($0.locale, $0.text) })
        #expect(texts == ["en-US": LocalizationText(name: "Spike Yearly", description: "Synthetic yearly plan"),
                          "cs": LocalizationText(name: "Spike na rok", description: "Synteticky rocni plan")])
        let shot = try #require(model.screenshots.first { $0.owner == .subscription(sub.id) })
        #expect(shot.state == "COMPLETE" && shot.received == FakeASC.samplePNG && shot.fileName == "shot-spike-a.png")
        let iap = try #require(model.iaps.first { $0.productId == "PurserSpikeLifetime_AB3" })
        #expect(report.created["iap-spike"] == iap.id)
        #expect(iap.type == "NON_CONSUMABLE" && iap.reviewNote == "Synthetic review note for the lifetime purchase" && !iap.familySharable)
        #expect(iap.availableTerritories == Set(model.territories.keys) && model.availabilityInNew[iap.id] == false)
        #expect(model.screenshots.first { $0.owner == .iap(iap.id) }?.state == "COMPLETE")
        let assets = await run.h.fake.assetRequests()
        #expect(assets.filter { $0.method == "GET" }.count == 2)
        #expect(assets.filter { $0.method == "PUT" }.count == 4)
        #expect(assets.allSatisfy { !$0.hadAuthorization })
    }

    @Test func everyRequestIsAuditedAndUploadsKeepNoQuery() async throws {
        let run = try await start()
        _ = try await run.creator().clone(Self.request(), snapshot: run.snapshot)
        let events = try run.h.audit.events(after: 0, limit: 1000).filter { $0.type == .httpSent || $0.type == .httpReceived }
        let writes = await run.h.fake.writeRequests()
        #expect(events.filter { $0.type == .httpSent }.count == writes.count)
        #expect(events.filter { $0.type == .httpReceived }.count == writes.count)
        let uploads = events.filter { $0.type == .httpSent && $0.refs["request"] == "upload" }
        #expect(uploads.count == 4)
        for event in uploads {
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any])
            #expect(payload["scheme"] as? String == "https")
            #expect(payload["host"] as? String == FakeASC.uploadHost)
            #expect(payload["path"] == nil)          // scheme and host only: a pre-signed path can carry a secret
            #expect(payload["offset"] as? Int != nil && payload["length"] as? Int != nil)
        }
        #expect(!events.contains { $0.payloadJSON.contains("synthetic-upload-token") })
    }

    @Test func aNewGroupGetsTheTextsOfTheSourceGroup() async throws {
        let run = try await start()
        let request = Self.request([Self.yearly], group: .newGroup(name: "Purser Spike B"))
        let steps = try await run.creator().previewClone(request, snapshot: run.snapshot).steps
        #expect(Array(steps.prefix(3)) == [.group(name: "Purser Spike B"), .groupLocalization(locale: "en-US"), .product(Self.yearly)])
        let report = try await run.creator().clone(request, snapshot: run.snapshot)
        #expect(Self.allCreated(report))
        let model = await run.h.fake.model
        let group = try #require(model.groups.first { $0.name == "Purser Spike B" })
        let version = try #require(model.versions.first { $0.owner == .group(group.id) })
        #expect(model.localizations.filter { $0.versionId == version.id }.map(\.text)
                == [LocalizationText(name: "Purser Spike Pro", customAppName: "Spike")])
        let sub = try #require(model.subscriptions.first { $0.productId == "SpikeYearlyA_AB3" })
        #expect(sub.groupId == group.id && sub.groupLevel == 1)
    }

    @Test func aNewGroupNamedLikeAnUnrelatedGroupIsRefusedWhileTheSameRequestRunsAgain() async throws {
        let run = try await start()
        let request = Self.request([Self.yearly], group: .newGroup(name: "Purser Spike B"))
        _ = try await run.creator().clone(request, snapshot: run.snapshot)
        let snapshot = try await run.h.initialSync()
        // The group holds only this request's clone: the request runs again and finds nothing to do.
        #expect(try await run.creator().previewClone(request, snapshot: snapshot).steps.isEmpty)
        #expect(try await run.creator().clone(request, snapshot: snapshot).steps.isEmpty)

        let writes = await run.h.fake.writeRequests().count
        let prompts = run.gate.prompts
        let other = CloneItem(source: .subscription("sub-spike-a"), productId: "SpikeYearlyA_AB4", name: "SpikeYearlyA_AB4")
        // The catalog knows that group and its clone, which is not one of this request's.
        await #expect(throws: ProductCreationError.invalid(["A group named “Purser Spike B” already exists with other subscriptions; choose a name no group has."])) {
            _ = try await run.creator().clone(Self.request([other], group: .newGroup(name: "Purser Spike B")), snapshot: snapshot)
        }
        // App Store Connect has a group the catalog does not know yet: the run reads it before it writes.
        await run.h.fake.mutate { model in
            model.groups.append(FakeGroup(id: "grp-x", name: "Purser Spike C"))
            model.subscriptions.append(FakeSubscription(id: "sub-x", productId: "Unrelated", name: "Unrelated", period: .oneYear,
                                                        state: .missingMetadata, groupId: "grp-x", availableTerritories: []))
        }
        let late = Self.request([other], group: .newGroup(name: "Purser Spike C"))
        #expect(ClonePlanner.problems(late, snapshot: snapshot).isEmpty)
        let refusal = ProductCreationError.invalid(["A group named “Purser Spike C” already exists in App Store Connect with other subscriptions; choose a name no group has."])
        await #expect(throws: refusal) { _ = try await run.creator().previewClone(late, snapshot: snapshot) }
        await #expect(throws: refusal) { _ = try await run.creator().clone(late, snapshot: snapshot) }
        #expect(await run.h.fake.writeRequests().count == writes)
        #expect(run.gate.prompts == prompts)
    }

    @Test func theEndLevelPutsTheCloneBelowEveryLevelOfTheGroup() async throws {
        let run = try await start()
        _ = try await run.creator().clone(Self.request([Self.yearly], level: .end), snapshot: run.snapshot)
        #expect(await run.h.fake.model.subscriptions.first { $0.productId == "SpikeYearlyA_AB3" }?.groupLevel == 2)
    }

    @Test func aRerunAtTheEndLevelGivesTheMissingCloneTheLevelOfACleanRun() async throws {
        let yearly = CloneItem(source: .subscription("sub-y"), productId: "Yearly_AB3", name: "Yearly_AB3")
        let monthly = CloneItem(source: .subscription("sub-m"), productId: "Monthly_AB3", name: "Monthly_AB3")
        let request = Self.request([yearly, monthly], level: .end)
        func levels(_ h: ExecutorHarness) async -> [String: Int] {
            Dictionary(uniqueKeysWithValues: await h.fake.model.subscriptions.filter { $0.productId.hasSuffix("_AB3") }
                .map { ($0.productId, $0.groupLevel ?? 0) })
        }
        // A clean run: "Premium" holds levels 1 to 3, so the clones take 4 and 5.
        let clean = try await start()
        _ = try await clean.creator().clone(request, snapshot: clean.snapshot)
        #expect(await levels(clean.h) == ["Yearly_AB3": 4, "Monthly_AB3": 5])

        // The monthly clone's POST is refused: its Product ID turns up in App Store Connect right after Touch ID.
        let run = try await start()
        let fake = run.h.fake
        let blocker = ActionGate {
            await fake.mutate { $0.iaps.append(FakeIAP(id: "iap-block", productId: "Monthly_AB3", name: "Blocker", type: "NON_CONSUMABLE",
                                                       state: .missingMetadata)) }
        }
        let first = try await run.h.makeProductCreator(gate: blocker).clone(request, snapshot: run.snapshot)
        #expect(first.created["sub-y"] != nil && first.created["sub-m"] == nil)
        await fake.mutate { $0.iaps.removeAll { $0.id == "iap-block" } }
        let second = try await run.creator().clone(request, snapshot: try await run.h.initialSync())
        #expect(second.created.keys.sorted() == ["sub-m", "sub-y"])
        let rerun = await levels(run.h)
        #expect(rerun == ["Yearly_AB3": 4, "Monthly_AB3": 5])
    }

    @Test func aRefusedProductSkipsItsStepsAndTheNextRunAddsOnlyWhatIsMissing() async throws {
        let run = try await start()
        await run.h.fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Synthetic refusal"), times: 1, matching: .method("POST"))
        let first = try await run.creator().clone(Self.request(), snapshot: run.snapshot)
        #expect(first.steps.count == 9)
        if case .failed = first.steps[0].outcome {} else { Issue.record("the product should fail: \(first.steps[0])") }
        #expect(first.steps[1...4].allSatisfy(Self.isSkipped))
        #expect(first.steps[5...].allSatisfy { if case .created = $0.outcome { return true } else { return false } })
        #expect(first.created["sub-spike-a"] == nil && first.created["iap-spike"] != nil)

        let snapshot = try await run.h.initialSync()
        let rest = try await run.creator().previewClone(Self.request(), snapshot: snapshot).steps
        #expect(rest.count == 5 && rest.first == .product(Self.yearly))
        let before = await run.h.fake.writeRequests().count
        let second = try await run.creator().clone(Self.request(), snapshot: snapshot)
        #expect(Self.allCreated(second) && second.steps.count == 5)
        #expect(second.created.keys.sorted() == ["iap-spike", "sub-spike-a"])
        let later = await run.h.fake.writeRequests().dropFirst(before)
        #expect(!later.contains { $0.path == "/v2/inAppPurchases" })
    }

    @Test func aRefusedTextIsAddedByTheNextRun() async throws {
        let run = try await start()
        await run.h.fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Synthetic refusal"), times: 1,
                                matching: .pathPrefix("/v2/subscriptionLocalizations"))
        let first = try await run.creator().clone(Self.request([Self.yearly]), snapshot: run.snapshot)
        #expect(first.steps.map(\.step)[2] == .localization(productId: "SpikeYearlyA_AB3", locale: "cs"))
        if case .failed = first.steps[2].outcome {} else { Issue.record("the cs text should fail: \(first.steps[2])") }
        if case .created = first.steps[3].outcome {} else { Issue.record("the en-US text should be created: \(first.steps[3])") }
        let snapshot = try await run.h.initialSync()
        #expect(try await run.creator().previewClone(Self.request([Self.yearly]), snapshot: snapshot).steps
                == [.localization(productId: "SpikeYearlyA_AB3", locale: "cs")])
        let second = try await run.creator().clone(Self.request([Self.yearly]), snapshot: snapshot)
        #expect(Self.allCreated(second) && second.steps.count == 1)
        // Touch ID names the work left, not the products in the request.
        #expect(run.gate.reasons.map { $0.contains(": 5 steps to write") } == [true, false])
        #expect(run.gate.reasons.last?.contains(": 1 step to write") == true)
    }

    @Test func anUploadThatFailsLeavesAReservationThatTheNextRunReplaces() async throws {
        let run = try await start()
        await run.h.fake.inject(.serverError(status: 500, applyFirst: false), times: 1, matching: .pathPrefix("/screenshot/"))
        let first = try await run.creator().clone(Self.request([Self.yearly]), snapshot: run.snapshot)
        guard case let .failed(reason)? = first.steps.last?.outcome else { Issue.record("the screenshot should fail"); return }
        #expect(reason.contains("HTTP 500"))
        let cloneId = try #require(first.created["sub-spike-a"])
        let stale = try #require(await run.h.fake.model.screenshots.first { $0.owner == .subscription(cloneId) })
        #expect(stale.state == "AWAITING_UPLOAD")

        let snapshot = try await run.h.initialSync()
        // This session made the reservation, so the run may delete it: the step is not blocked.
        #expect(try await run.creator().previewClone(Self.request([Self.yearly]), snapshot: snapshot)
                == ClonePreview(steps: [.reviewScreenshot(productId: "SpikeYearlyA_AB3")], blocked: [:]))
        let before = await run.h.fake.writeRequests().count
        let second = try await run.creator().clone(Self.request([Self.yearly]), snapshot: snapshot)
        #expect(Self.allCreated(second))
        let writes = (await run.h.fake.writeRequests()).dropFirst(before).filter { $0.host == FakeASC.apiHost }.map { "\($0.method) \($0.path)" }
        #expect(writes.first == "DELETE /v1/subscriptionAppStoreReviewScreenshots/\(stale.id)")
        #expect(writes.dropFirst().map { $0.split(separator: " ").first.map(String.init) ?? "" } == ["POST", "PATCH"])
        let shots = await run.h.fake.model.screenshots.filter { $0.owner == .subscription(cloneId) }
        #expect(shots.count == 1 && shots.first?.state == "COMPLETE")
    }

    static let earlierSessionReservation = "A review screenshot Purser cannot replace is in the way (an unfinished upload from an earlier run). Remove it in App Store Connect (the product's Review Information), then run the clone again."

    /// The yearly clone with an upload that failed, so its screenshot is an unfinished reservation of this session.
    private func cloneWithUnfinishedScreenshot(_ run: Run) async throws -> (cloneId: String, stale: FakeScreenshot) {
        await run.h.fake.inject(.serverError(status: 500, applyFirst: false), times: 1, matching: .pathPrefix("/screenshot/"))
        let first = try await run.creator().clone(Self.request([Self.yearly]), snapshot: run.snapshot)
        let cloneId = try #require(first.created["sub-spike-a"])
        let stale = try #require(await run.h.fake.model.screenshots.first { $0.owner == .subscription(cloneId) })
        return (cloneId, stale)
    }

    /// A creator after a relaunch: the session's new AppGuard never saw this session's reservations, so it may not delete them.
    private func relaunchedCreator(_ run: Run) async throws -> ProductCreator {
        let relaunched = AppGuard(appId: FakeSeed.appId)
        let reader = LiveASCClient(http: try await WriteTestClients.http(transport: run.h.fake, readOnly: true, products: [], budget: run.h.budget,
                                                                         appGuard: relaunched, now: run.h.clock.nowFunction))
        let http = try await WriteTestClients.http(transport: run.h.fake, readOnly: false, products: [], budget: run.h.budget,
                                                   appGuard: relaunched, now: run.h.clock.nowFunction)
        return ProductCreator(config: run.h.config, http: http, reader: reader, audit: run.h.audit, budget: run.h.budget,
                              gate: run.gate, runs: ProductRuns(), assets: AssetTransfer(transport: run.h.fake, audit: run.h.audit))
    }

    @Test func aReservationLeftBeforeARelaunchIsLeftAloneAndTheOwnerIsToldWhatToDo() async throws {
        let run = try await start()
        let (cloneId, stale) = try await cloneWithUnfinishedScreenshot(run)
        let snapshot = try await run.h.initialSync()
        let creator = try await relaunchedCreator(run)
        let screenshot = CloneStep.reviewScreenshot(productId: "SpikeYearlyA_AB3")

        // The preview shows the step as blocked, with what the owner has to do.
        let preview = try await creator.previewClone(Self.request([Self.yearly]), snapshot: snapshot)
        #expect(preview == ClonePreview(steps: [screenshot], blocked: [screenshot: Self.earlierSessionReservation]))
        #expect(preview.writable.isEmpty)

        let writes = await run.h.fake.writeRequests().count
        let assets = await run.h.fake.assetRequests().count
        let sent = try run.h.audit.events(after: 0, limit: 1000).filter { $0.type == .httpSent }.count
        let prompts = run.gate.prompts
        let report = try await creator.clone(Self.request([Self.yearly]), snapshot: snapshot)
        #expect(report.steps == [CloneStepReport(step: screenshot, outcome: .failed(Self.earlierSessionReservation))])
        // Nothing can be written, so nothing asks for Touch ID.
        #expect(run.gate.prompts == prompts)
        #expect(await run.h.fake.writeRequests().count == writes)
        #expect(await run.h.fake.assetRequests().count == assets)
        #expect(try run.h.audit.events(after: 0, limit: 1000).filter { $0.type == .httpSent }.count == sent)
        #expect(await run.h.fake.model.screenshots.first { $0.owner == .subscription(cloneId) } == stale)
    }

    @Test func aBlockedScreenshotIsLeftOutOfTouchIDAndTheRestIsWritten() async throws {
        let run = try await start()
        _ = try await cloneWithUnfinishedScreenshot(run)
        let snapshot = try await run.h.initialSync()
        let creator = try await relaunchedCreator(run)
        let screenshot = CloneStep.reviewScreenshot(productId: "SpikeYearlyA_AB3")
        let preview = try await creator.previewClone(Self.request(), snapshot: snapshot)
        #expect(preview.steps.first == screenshot && preview.steps.count == 5)
        #expect(preview.blocked == [screenshot: Self.earlierSessionReservation])
        #expect(preview.writable == Array(preview.steps.dropFirst()))

        let report = try await creator.clone(Self.request(), snapshot: snapshot)
        #expect(report.steps.first == CloneStepReport(step: screenshot, outcome: .failed(Self.earlierSessionReservation)))
        #expect(report.steps.dropFirst().allSatisfy { if case .created = $0.outcome { return true } else { return false } })
        #expect(run.gate.reasons.last?.contains(": 4 steps to write") == true)
    }

    @Test func onlyTheClonesOwnReservationIsDeletedNeverTheSourceScreenshot() async throws {
        let run = try await start()
        let source = try #require(await run.h.fake.model.screenshots.first { $0.owner == .subscription("sub-spike-a") })
        await run.h.fake.inject(.serverError(status: 500, applyFirst: false), times: 1, matching: .pathPrefix("/screenshot/"))
        let first = try await run.creator().clone(Self.request([Self.yearly]), snapshot: run.snapshot)
        let cloneId = try #require(first.created["sub-spike-a"])
        let stale = try #require(await run.h.fake.model.screenshots.first { $0.owner == .subscription(cloneId) })
        let snapshot = try await run.h.initialSync()

        // A read that reports the source's screenshot as the clone's uncommitted reservation: the creator leaves it alone
        // and never even asks for its DELETE (nothing in the audit), whatever AppGuard would say.
        let swapped = SwappedScreenshotReader(inner: run.h.reader, screenshots: [.subscription(cloneId): ReviewScreenshot(
            ascId: source.id, fileName: source.fileName, fileSize: source.fileSize, templateURL: nil, width: nil, height: nil,
            deliveryState: "AWAITING_UPLOAD")])
        let refused = try await run.h.makeProductCreator(gate: run.gate, reader: swapped).clone(Self.request([Self.yearly]), snapshot: snapshot)
        guard case let .failed(reason)? = refused.steps.last?.outcome else { Issue.record("the screenshot should fail: \(refused)"); return }
        #expect(reason.contains(source.id))

        // The clone's own reservation is the one the next run deletes.
        let second = try await run.creator().clone(Self.request([Self.yearly]), snapshot: snapshot)
        #expect(Self.allCreated(second))
        let changes = await run.h.fake.writeRequests().filter { $0.method == "DELETE" || $0.method == "PATCH" }.map { "\($0.method) \($0.path)" }
        #expect(!changes.contains { $0.hasSuffix("/\(source.id)") })
        #expect(changes.filter { $0.hasPrefix("DELETE") } == ["DELETE /v1/subscriptionAppStoreReviewScreenshots/\(stale.id)"])
        let sent = try run.h.audit.events(after: 0, limit: 1000).filter { $0.type == .httpSent }.compactMap { event in
            (try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any])?["path"] as? String
        }
        #expect(!sent.contains { $0.hasSuffix("/\(source.id)") })
        #expect(await run.h.fake.model.screenshots.first { $0.id == source.id } == source)
    }

    @Test func aCloneOfACloneNeverChangesTheFirstClonesFinishedScreenshot() async throws {
        let run = try await start()
        let first = try await run.creator().clone(Self.request([Self.yearly]), snapshot: run.snapshot)
        let firstClone = try #require(first.created["sub-spike-a"])
        // Reserved and committed by this session's own client: finished, so no longer the client's to change.
        let finished = try #require(await run.h.fake.model.screenshots.first { $0.owner == .subscription(firstClone) })
        #expect(finished.state == "COMPLETE")
        let item = CloneItem(source: .subscription(firstClone), productId: "SpikeYearlyA_AB3_C2", name: "SpikeYearlyA_AB3_C2")
        _ = try await run.creator().clone(Self.request([item], copy: CloneCopy(reviewScreenshot: false)), snapshot: try await run.h.initialSync())
        let snapshot = try await run.h.initialSync()
        let secondClone = try #require(await run.h.fake.model.subscriptions.first { $0.productId == item.productId }?.id)

        // Past the creator's own check: the source reads as another finished screenshot, and the second clone's screenshot
        // as the first clone's one left unfinished. AppGuard still refuses to change it.
        let other = try #require(try await run.h.reader.reviewScreenshot(of: .subscription("sub-spike-a")))
        let swapped = SwappedScreenshotReader(inner: run.h.reader, screenshots: [
            .subscription(firstClone): other,
            .subscription(secondClone): ReviewScreenshot(ascId: finished.id, fileName: finished.fileName, fileSize: finished.fileSize,
                                                         templateURL: nil, width: nil, height: nil, deliveryState: "AWAITING_UPLOAD"),
        ])
        let before = await run.h.fake.writeRequests().count
        let report = try await run.h.makeProductCreator(gate: run.gate, reader: swapped).clone(Self.request([item]), snapshot: snapshot)
        #expect(report.steps.map(\.step) == [.reviewScreenshot(productId: item.productId)])
        #expect(report.steps.first?.outcome == .failed(Self.earlierSessionReservation))
        #expect(!(await run.h.fake.writeRequests()).dropFirst(before).contains { $0.path.hasSuffix("/\(finished.id)") })

        let write = try await WriteTestClients.http(transport: run.h.fake, readOnly: false, products: [], budget: run.h.budget,
                                                    appGuard: run.h.appGuard, now: run.h.clock.nowFunction)
        let path = "/v1/subscriptionAppStoreReviewScreenshots/\(finished.id)"
        let commit = Data(#"{"data":{"type":"subscriptionAppStoreReviewScreenshots","id":"\#(finished.id)","attributes":{"uploaded":true,"sourceFileChecksum":"00"}}}"#.utf8)
        await #expect(throws: ASCError.foreignResource(path)) { try await write.delete(path: path) }
        await #expect(throws: ASCError.foreignResource(path)) { _ = try await write.send(method: "PATCH", path: path, body: commit) }
        #expect(await run.h.fake.model.screenshots.first { $0.id == finished.id } == finished)
    }

    @Test func aRequestThatMayHaveReachedAppleStopsTheRun() async throws {
        let run = try await start()
        await run.h.fake.inject(.timeoutAfterApply, times: 1, matching: .method("POST"))
        let first = try await run.creator().clone(Self.request(), snapshot: run.snapshot)
        if case .failed = first.steps[0].outcome {} else { Issue.record("the product should fail: \(first.steps[0])") }
        #expect(first.steps.dropFirst().allSatisfy { entry in
            if case let .skipped(reason) = entry.outcome { return reason.contains("may have reached Apple") } else { return false }
        })
        // The subscription exists in App Store Connect; the next run takes it over and adds the rest.
        let snapshot = try await run.h.initialSync()
        let rest = try await run.creator().previewClone(Self.request(), snapshot: snapshot).steps
        #expect(!rest.contains(.product(Self.yearly)))
        #expect(rest.contains(.availability(productId: "SpikeYearlyA_AB3")))
    }

    @Test func invalidRequestsAndAWrongAppSendNothing() async throws {
        let run = try await start()
        let creator = try await run.creator()
        let own = CloneItem(source: .subscription("sub-spike-a"), productId: "SpikeYearlyA", name: "Copy")
        let taken = CloneItem(source: .subscription("sub-spike-a"), productId: "com.example.fruitjar.monthly", name: "Copy")
        let other = CloneItem(source: .subscription("sub-y"), productId: "Yearly_AB3", name: "Yearly_AB3")
        for request in [Self.request([own]), Self.request([taken]), Self.request([]),
                        Self.request([other, Self.yearly], group: .newGroup(name: "B"))] {
            await #expect(throws: ProductCreationError.self) { _ = try await creator.clone(request, snapshot: run.snapshot) }
        }
        await run.h.fake.mutate { $0.app.bundleId = "com.example.other" }
        await #expect(throws: ProductCreationError.bindingMismatch("\(FakeSeed.appId) com.example.other")) {
            _ = try await creator.clone(Self.request(), snapshot: run.snapshot)
        }
        #expect(await run.h.fake.writeRequests().isEmpty)
        #expect(run.gate.prompts == 0)
    }

    @Test func withoutAnAssetTransferOnlyTheScreenshotsFail() async throws {
        let run = try await start()
        let report = try await run.creator(copiesImages: false).clone(Self.request(), snapshot: run.snapshot)
        for entry in report.steps {
            switch (entry.step, entry.outcome) {
            case (.reviewScreenshot, .failed), (.product, .created), (.availability, .created), (.localization, .created): continue
            default: Issue.record("unexpected \(entry)")
            }
        }
        #expect(await run.h.fake.assetRequests().isEmpty)
    }

    @Test func refusedTouchIDStopsTheCloneBeforeAnyWrite() async throws {
        let run = try await start()
        let creator = try await run.h.makeProductCreator(gate: RefusingGate())
        #expect(!(try await creator.previewClone(Self.request(), snapshot: run.snapshot)).steps.isEmpty)
        await #expect(throws: BiometricError.notAuthenticated) { _ = try await creator.clone(Self.request(), snapshot: run.snapshot) }
        #expect(await run.h.fake.writeRequests().isEmpty)
        #expect(await run.h.fake.assetRequests().isEmpty)
        #expect(try run.h.audit.events(after: 0, limit: 1000).allSatisfy { $0.type != .httpSent })
    }

    // MARK: One run at a time

    static let oneMore = ProductCreationRequest(groupName: nil, subscriptions: [],
                                                nonConsumables: [NewNonConsumableProduct(productId: "OneMoreLifetime", name: "OneMoreLifetime")])

    @Test func aSecondRunIsRefusedWhileACloneRunsAndReadsNothing() async throws {
        let run = try await start()
        let runs = ProductRuns()
        let second = try await run.h.makeProductCreator(runs: runs)
        let fake = run.h.fake
        let snapshot = run.snapshot
        let refusals = Locked<[ProductCreationError]>([])
        let requests = Locked<[Int]>([])
        let gate = ActionGate {
            requests.update { $0.append(0) }
            let before = await fake.requests().count
            do { _ = try await second.clone(Self.request(), snapshot: snapshot) } catch let error as ProductCreationError {
                refusals.update { $0.append(error) }
            } catch {}
            do { _ = try await second.create(Self.oneMore) } catch let error as ProductCreationError {
                refusals.update { $0.append(error) }
            } catch {}
            let after = await fake.requests().count
            requests.update { $0 = [before, after] }
        }
        let report = try await run.h.makeProductCreator(gate: gate, runs: runs).clone(Self.request(), snapshot: run.snapshot)
        #expect(Self.allCreated(report))
        #expect(refusals.value == [.anotherRunInProgress(.clone), .anotherRunInProgress(.clone)])
        #expect(requests.value.count == 2 && requests.value[0] == requests.value[1])
        #expect(runs.running == nil)
        // The run is over: the next one starts.
        #expect(try await second.create(Self.oneMore).count == 2)
    }

    @Test func aCloneIsRefusedWhileNewProductsAreCreated() async throws {
        let run = try await start()
        let runs = ProductRuns()
        let second = try await run.h.makeProductCreator(runs: runs)
        let snapshot = run.snapshot
        let refusals = Locked<[ProductCreationError]>([])
        let gate = ActionGate {
            #expect(runs.running == .creation)
            do { _ = try await second.clone(Self.request(), snapshot: snapshot) } catch let error as ProductCreationError {
                refusals.update { $0.append(error) }
            } catch {}
        }
        #expect(try await run.h.makeProductCreator(gate: gate, runs: runs).create(Self.oneMore).count == 2)
        #expect(refusals.value == [.anotherRunInProgress(.creation)])
        #expect(runs.running == nil)
    }

    @Test func aRunThatFailsLetsTheNextOneStart() async throws {
        let run = try await start()
        let runs = ProductRuns()
        await #expect(throws: BiometricError.notAuthenticated) {
            _ = try await run.h.makeProductCreator(gate: RefusingGate(), runs: runs).clone(Self.request(), snapshot: run.snapshot)
        }
        #expect(runs.running == nil)
        #expect(Self.allCreated(try await run.h.makeProductCreator(runs: runs).clone(Self.request(), snapshot: run.snapshot)))
    }

    @Test func aCloneHeldForItsDraftsKeepsTheRunMarkedUntilTheClaimIsReleased() async throws {
        let run = try await start()
        let runs = ProductRuns()
        let creator = try await run.h.makeProductCreator(runs: runs)
        let claim = try runs.claim(.clone)
        let report = try await creator.clone(Self.request(), snapshot: run.snapshot, holding: claim)
        #expect(Self.allCreated(report))
        // The clone is over, its drafts phase is not: a second run, a new claim and a creation are all refused, and nothing is read.
        #expect(runs.running == .clone)
        let before = await run.h.fake.requests().count
        await #expect(throws: ProductCreationError.anotherRunInProgress(.clone)) {
            _ = try await creator.clone(Self.request(), snapshot: run.snapshot)
        }
        #expect(throws: ProductCreationError.anotherRunInProgress(.clone)) { _ = try runs.claim(.clone) }
        await #expect(throws: ProductCreationError.anotherRunInProgress(.clone)) { _ = try await creator.create(Self.oneMore) }
        #expect(await run.h.fake.requests().count == before)
        claim.release()
        #expect(runs.running == nil)
        #expect(Self.allCreated(try await creator.clone(Self.request(), snapshot: run.snapshot)))
    }

    @Test func aHeldCloneThatFailsLeavesTheClaimToItsOwner() async throws {
        let run = try await start()
        let runs = ProductRuns()
        let claim = try runs.claim(.clone)
        await #expect(throws: BiometricError.notAuthenticated) {
            _ = try await run.h.makeProductCreator(gate: RefusingGate(), runs: runs).clone(Self.request(), snapshot: run.snapshot, holding: claim)
        }
        #expect(runs.running == .clone)
        claim.release()
        #expect(runs.running == nil)
    }

    @Test func releasingAClaimTwiceDoesNotFreeALaterRun() throws {
        let runs = ProductRuns()
        let first = try runs.claim(.clone)
        first.release()
        let second = try runs.claim(.creation)
        first.release()
        #expect(runs.running == .creation)
        second.release()
        #expect(runs.running == nil)
    }

    @Test func aClaimThatIsDroppedReleasesTheRun() throws {
        let runs = ProductRuns()
        var claim: ProductRunClaim? = try runs.claim(.clone)
        #expect(claim != nil && runs.running == .clone)
        claim = nil
        #expect(runs.running == nil)
    }

    @Test func aRefusedRunSaysWhatIsRunning() {
        #expect(ProductCreationError.anotherRunInProgress(.clone).localizedDescription == "A clone is running in Purser; wait until it finishes.")
        #expect(ProductCreationError.anotherRunInProgress(.creation).localizedDescription
                == "New products are being created in Purser; wait until that finishes.")
    }

    @Test func whatExistsIsSkippedWithoutTouchID() async throws {
        let run = try await start()
        _ = try await run.creator().clone(Self.request(), snapshot: run.snapshot)
        let snapshot = try await run.h.initialSync()
        let gate = CountingGate()
        let again = try await run.h.makeProductCreator(gate: gate).clone(Self.request(), snapshot: snapshot)
        #expect(again.steps.isEmpty)
        #expect(again.created.count == 2)
        #expect(gate.prompts == 0)
    }
}
