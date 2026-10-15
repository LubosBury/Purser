import Foundation
import GRDB
import Testing
import ASCClient
import Audit
import Catalog
import Domain
import Store
import PurserTestSupport

/// One workspace database, a scripted ASC and a manual clock (starts 2026-10-09T12:00Z).
private struct Harness {
    let database: WorkspaceDatabase
    let reader: ScriptedReader
    let clock = ManualClock(Sample.fixedNow)
    let audit: AuditLog
    let engine: SyncEngine
    let catalog: CatalogStore

    init(_ script: ScriptedReader.Script = Harness.baseScript()) throws {
        database = try WorkspaceDatabase.inMemory()
        reader = ScriptedReader(script)
        let clock = self.clock
        audit = AuditLog(database: database, actor: { "001234.synthetic-owner.0001" }, now: { clock.now() })
        engine = SyncEngine(database: database, reader: reader, audit: audit, config: Sample.config(), now: { clock.now() })
        catalog = CatalogStore(database: database)
    }

    static func baseScript() -> ScriptedReader.Script {
        var script = ScriptedReader.Script()
        script.subscriptions = [Sample.subscription()]
        script.prices["6500000001"] = [
            Sample.regular("price-usa-1", territory: "USA", price: "29.99"),
            Sample.regular("price-cze-1", territory: "CZE", price: "799"),
        ]
        script.intros["6500000001"] = [Sample.intro("intro-usa-1", territory: "USA")]
        script.promos["6500000001"] = [Sample.promo("promo-1", code: "WINBACK_v1", prices: [("USA", "14.99"), ("CZE", "399")])]
        script.pricePoints["6500000001"] = [
            Sample.pricePoint(territory: "USA", price: "29.99"), Sample.pricePoint(territory: "USA", price: "34.99"),
            Sample.pricePoint(territory: "CZE", price: "799"), Sample.pricePoint(territory: "DEU", price: "29.99"),
        ]
        script.iaps = [Sample.iap()]
        script.schedules["6600000001"] = Sample.schedule(prices: [("USA", "49.99")])
        script.pricePoints["6600000001"] = [
            Sample.pricePoint("6600000001", territory: "USA", price: "49.99", planType: nil),
            Sample.pricePoint("6600000001", territory: "CZE", price: "1290", planType: nil),
            Sample.pricePoint("6600000001", territory: "DEU", price: "49.99", planType: nil),
        ]
        return script
    }

    func observations(_ kind: String) throws -> [ObservationRow] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT asc_id, provenance, first_sync, last_sync, expired FROM observation WHERE kind = ? ORDER BY id",
                             arguments: [kind]).map {
                ObservationRow(ascId: $0["asc_id"], provenance: $0["provenance"], firstSync: $0["first_sync"],
                               lastSync: $0["last_sync"], expired: $0["expired"])
            }
        }
    }

    func syncRun(_ id: Int64) throws -> (status: String, requests: Int, scopes: [String])? {
        try database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_run WHERE id = ?", arguments: [id]).map {
                ($0["status"], $0["request_count"], try JSONCoding.decode([String].self, from: $0["complete_scopes_json"]))
            }
        }
    }

    /// Stores a plan with one item in `state`, as the Executor will in M2.
    func recordPurserItem(_ payload: WritePayload, cell: CellKey, state: ItemState, ascId: String? = nil) throws {
        let store = PlanStore(database: database)
        let planId = "plan-\(UUID().uuidString.prefix(8))"
        let plan = StoredPlan(id: planId, origin: .fix, specJSON: "{}", importJSON: nil, binding: PlanBinding(config: Sample.config()),
                              baseSyncId: 1, state: .applying, pauseReason: nil, endReason: nil, planHash: "h", verdictHash: "v",
                              verdicts: [], excluded: [], productStates: [:], reason: nil, confirmationLevel: .c0, appBuild: "test",
                              estimateRequests: 1, estimateMinutes: 1, replanOf: nil, createdAt: clock.now(), updatedAt: clock.now(),
                              heartbeatAt: nil)
        let item = PlannedItem(seq: 1, cell: cell, payload: payload, before: .regular(current: nil, scheduled: nil),
                               target: .regular(current: nil, scheduled: nil))
        try store.insert(plan, items: [item])
        var stored = try #require(try store.items(planId: planId).first)
        stored.state = state
        stored.ascId = ascId
        try database.writer.write { db in try store.update(stored, in: db) }
    }
}

private struct ObservationRow: Equatable {
    var ascId: String
    var provenance: String
    var firstSync: Int64
    var lastSync: Int64
    var expired: Int
}

@Suite struct SyncEngineTests {
    private let usa = CellKey.regular(subscriptionId: "6500000001", territory: "USA", planType: .upfront)

    @Test func firstSyncIsBaselineWithoutFindings() async throws {
        let h = try Harness()
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.syncId == 1)
        #expect(result.status == .complete)
        #expect(result.newFindings.isEmpty)
        #expect(try h.observations("PRICE").map(\.provenance) == ["BASELINE", "BASELINE"])
        #expect(try h.observations("INTRO").count == 1)
        #expect(try h.observations("PROMO").count == 1)
        #expect(try h.observations("IAP_SCHEDULE").map(\.ascId) == ["6600000001"])
        #expect(try h.syncRun(1)?.scopes == ["6500000001|INTRO", "6500000001|LOCALIZATION", "6500000001|PRICE", "6500000001|PROMO",
                                             "6600000001|IAP_SCHEDULE", "6600000001|LOCALIZATION", "7000000001|LOCALIZATION"])

        let snapshot = try #require(try h.catalog.latestSnapshot())
        #expect(snapshot.syncId == 1)
        #expect(snapshot.subscriptions.keys.sorted() == ["6500000001"])
        #expect(snapshot.iaps.keys.sorted() == ["6600000001"])
        #expect(snapshot.territories.count == 3)
        #expect(snapshot.regularRows.count == 2)
        #expect(snapshot.offerCodesEverSeen == ["WINBACK_v1"])
        #expect(snapshot.pricePoints.points(productAscId: "6500000001", territory: "USA", planType: .upfront).count == 2)
        #expect(snapshot.pricePoints.points(productAscId: "6600000001", territory: "CZE", planType: nil).count == 1)
        #expect(snapshot.iapSchedules["6600000001"]?.baseTerritory == "USA")

        let events = try h.audit.events(after: 0, limit: 10).map(\.type)
        #expect(events == [.syncStarted, .syncFinished])
        #expect(try h.audit.verifyChain() == .ok(count: 2))
    }

    @Test func unchangedRowsOnlyExtendTheirVersionRange() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        let second = try await h.engine.sync(trigger: .nightly, scope: .all)
        #expect(second.newFindings.isEmpty)
        #expect(try h.observations("PRICE") == [
            ObservationRow(ascId: "price-usa-1", provenance: "BASELINE", firstSync: 1, lastSync: 2, expired: 0),
            ObservationRow(ascId: "price-cze-1", provenance: "BASELINE", firstSync: 1, lastSync: 2, expired: 0),
        ])
        #expect(try h.catalog.latestSnapshot()?.syncId == 2)
    }

    @Test func changedRowIsExternalAndKeepsItsHistory() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update { $0.prices["6500000001"]?[0] = Sample.regular("price-usa-1", territory: "USA", price: "34.99") }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.type) == [.external])
        #expect(result.newFindings.first?.cell == usa)
        #expect(result.newFindings.first?.message == "Regular price row price-usa-1 changed outside Purser")
        let history = try h.catalog.history(cell: usa)
        #expect(history.map(\.provenance) == [.baseline, .external])
        #expect(history.map(\.lastSync) == [1, 2])
        #expect(try h.catalog.latestSnapshot()?.regularPrice(subscriptionId: "6500000001", territory: "USA", planType: .upfront,
                                                             on: CalendarDate(year: 2026, month: 10, day: 9)) == Decimal(string: "34.99")!)
        let audited = try h.audit.events(after: 0, limit: 20).filter { $0.type == .findingRaised }
        #expect(audited.count == 1)
        #expect(audited.first?.refs["cell"] == usa.storageKey)
        // K3 refs keys: "finding" (not "findingId") and "syncId".
        #expect(audited.first?.refs["finding"] == result.newFindings.first.map { String($0.id) })
        #expect(audited.first?.refs["syncId"] == "2")
    }

    @Test func appearingRowIsExternal() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update { $0.intros["6500000001"]?.append(Sample.intro("intro-cze-1", territory: "CZE", mode: .payUpFront, duration: .threeMonths, price: "299")) }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.message) == ["Intro offer intro-cze-1 appeared outside Purser"])
        #expect(try h.observations("INTRO").last?.provenance == "EXTERNAL")
    }

    @Test func productSeenForTheFirstTimeIsBaseline() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update {
            $0.subscriptions.append(Sample.subscription("6500000002", productId: "fruit.monthly", period: .oneMonth))
            $0.prices["6500000002"] = [Sample.regular("m-usa-1", sub: "6500000002", territory: "USA", price: "4.99")]
        }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.isEmpty)
        #expect(try h.observations("PRICE").last == ObservationRow(ascId: "m-usa-1", provenance: "BASELINE", firstSync: 2, lastSync: 2, expired: 0))
    }

    @Test func rowMatchingAWrittenPurserItemByNaturalKeyIsPurser() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        try h.recordPurserItem(.createRegularPrice(NewRegularPrice(subscriptionId: "6500000001", territory: "USA", planType: .upfront,
                                                                   pricePointId: "pp-USA-34.99", startDate: CalendarDate(iso: "2026-11-01"),
                                                                   preserveCurrentPrice: true)),
                               cell: usa, state: .done)
        h.reader.update { $0.prices["6500000001"]?.append(Sample.regular("price-usa-2", territory: "USA", price: "34.99", start: "2026-11-01")) }
        let result = try await h.engine.sync(trigger: .verify, scope: .products(["6500000001"]))
        #expect(result.newFindings.isEmpty)
        #expect(try h.observations("PRICE").last?.provenance == "PURSER")
    }

    @Test func rowMatchingAWrittenPurserItemByAscIdIsPurser() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        try h.recordPurserItem(.createIntro(NewIntroOffer(subscriptionId: "6500000001", territory: "CZE", planType: .upfront, mode: .freeTrial,
                                                         duration: .oneWeek, numberOfPeriods: 1, startDate: nil, endDate: nil, pricePointId: nil)),
                               cell: .intro(subscriptionId: "6500000001", territory: "CZE", planType: .upfront), state: .done, ascId: "intro-cze-9")
        // ASC filled in a start date, so the natural key no longer matches; the asc id still does.
        h.reader.update { $0.intros["6500000001"]?.append(Sample.intro("intro-cze-9", territory: "CZE", start: "2026-10-09")) }
        let result = try await h.engine.sync(trigger: .verify, scope: .all)
        #expect(result.newFindings.isEmpty)
        #expect(try h.observations("INTRO").last?.provenance == "PURSER")
    }

    @Test func pendingItemsDoNotExplainChanges() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        try h.recordPurserItem(.createRegularPrice(NewRegularPrice(subscriptionId: "6500000001", territory: "USA", planType: .upfront,
                                                                   pricePointId: "pp-USA-34.99", startDate: CalendarDate(iso: "2026-11-01"),
                                                                   preserveCurrentPrice: false)),
                               cell: usa, state: .pending)
        h.reader.update { $0.prices["6500000001"]?.append(Sample.regular("price-usa-2", territory: "USA", price: "34.99", start: "2026-11-01")) }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.type) == [.external])
    }

    @Test func introPastItsEndDateExpiresSilently() async throws {
        var script = Harness.baseScript()
        script.intros["6500000001"] = [Sample.intro("intro-usa-1", territory: "USA", start: "2026-01-01", end: "2026-10-10")]
        let h = try Harness(script)
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.clock.advance(by: 2 * 86_400)
        h.reader.update { $0.intros["6500000001"] = [] }
        let result = try await h.engine.sync(trigger: .nightly, scope: .all)
        #expect(result.newFindings.isEmpty)
        #expect(try h.observations("INTRO").first?.expired == 1)
    }

    @Test func supersededRegularRowExpiresSilently() async throws {
        var script = Harness.baseScript()
        script.prices["6500000001"] = [
            Sample.regular("price-usa-1", territory: "USA", price: "29.99"),
            Sample.regular("price-usa-2", territory: "USA", price: "34.99", start: "2026-10-11"),
        ]
        let h = try Harness(script)
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.clock.advance(by: 3 * 86_400)
        h.reader.update { $0.prices["6500000001"] = [Sample.regular("price-usa-2", territory: "USA", price: "34.99", start: "2026-10-11")] }
        let result = try await h.engine.sync(trigger: .nightly, scope: .all)
        #expect(result.newFindings.isEmpty)
        #expect(try h.observations("PRICE").first { $0.ascId == "price-usa-1" }?.expired == 1)
    }

    @Test func disappearedRowIsExternal() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update { $0.prices["6500000001"]?.removeAll { $0.ascId == "price-cze-1" } }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.message) == ["Regular price row price-cze-1 disappeared outside Purser"])
        #expect(result.newFindings.first?.type == .external)
    }

    @Test func disappearedPurserRowIsScheduleBroken() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        try h.recordPurserItem(.createRegularPrice(NewRegularPrice(subscriptionId: "6500000001", territory: "USA", planType: .upfront,
                                                                   pricePointId: "pp-USA-34.99", startDate: CalendarDate(iso: "2026-11-01"),
                                                                   preserveCurrentPrice: true)),
                               cell: usa, state: .done)
        h.reader.update { $0.prices["6500000001"]?.append(Sample.regular("price-usa-2", territory: "USA", price: "34.99", start: "2026-11-01")) }
        _ = try await h.engine.sync(trigger: .verify, scope: .all)
        h.reader.update { $0.prices["6500000001"]?.removeAll { $0.ascId == "price-usa-2" } }
        let result = try await h.engine.sync(trigger: .nightly, scope: .all)
        #expect(result.newFindings.map(\.type) == [.scheduleBroken])
        #expect(result.newFindings.first?.message == "Regular price row price-usa-2 written by Purser disappeared")
    }

    @Test func disappearanceExplainedByAPurserDeleteRaisesNothing() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        try h.recordPurserItem(.deleteRegularPrice(ascId: "price-cze-1"),
                               cell: .regular(subscriptionId: "6500000001", territory: "CZE", planType: .upfront), state: .done)
        h.reader.update { $0.prices["6500000001"]?.removeAll { $0.ascId == "price-cze-1" } }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.isEmpty)
    }

    @Test func incompleteScopeKeepsPreviousRowsAndRaisesNothing() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update {
            $0.prices["6500000001"] = []
            $0.failures["regularPrices:6500000001"] = .network(description: "offline", maybeSent: false)
        }
        let result = try await h.engine.sync(trigger: .nightly, scope: .all)
        #expect(result.status == .partial)
        #expect(result.newFindings.isEmpty)
        #expect(try h.syncRun(2)?.scopes.contains("6500000001|PRICE") == false)
        let snapshot = try #require(try h.catalog.latestSnapshot())
        #expect(snapshot.syncId == 2)
        #expect(snapshot.regularRows.map(\.ascId).sorted() == ["price-cze-1", "price-usa-1"])

        // The next complete read compares against sync 1, the last complete read of that scope.
        h.reader.update { $0.failures = [:] }
        let third = try await h.engine.sync(trigger: .nightly, scope: .all)
        #expect(third.newFindings.count == 2)
    }

    @Test func productScopeReadsOnlyThoseProducts() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        let before = h.reader.calls.count
        let result = try await h.engine.sync(trigger: .preflight, scope: .products(["6500000001"]))
        let calls = Array(h.reader.calls.dropFirst(before))
        #expect(!calls.contains("territories"))
        #expect(!calls.contains("iapPriceSchedule:6600000001"))
        #expect(calls.contains("regularPrices:6500000001"))
        #expect(result.requestCount == calls.count)
        #expect(try h.syncRun(2)?.scopes == ["6500000001|INTRO", "6500000001|LOCALIZATION", "6500000001|PRICE", "6500000001|PROMO"])
        #expect(!calls.contains("metadata:G|7000000001"))
        // The IAP schedule is still shown from sync 1.
        #expect(try h.catalog.latestSnapshot()?.iapSchedules["6600000001"] != nil)
    }

    @Test func bundleIdMismatchFailsTheSync() async throws {
        var script = Harness.baseScript()
        script.app = ASCApp(id: Sample.appId, bundleId: "com.example.otherapp", name: "Other")
        let h = try Harness(script)
        await #expect(throws: SyncError.bundleIdMismatch(expected: Sample.bundleId, actual: "com.example.otherapp")) {
            _ = try await h.engine.sync(trigger: .manual, scope: .all)
        }
        #expect(try h.syncRun(1)?.status == "failed")
        #expect(try h.observations("PRICE").isEmpty)
        #expect(try h.catalog.latestSnapshot() == nil)
        let last = try #require(try h.audit.events(after: 0, limit: 10).last)
        #expect(last.type == .syncFinished)
        #expect(last.payloadJSON.contains("\"status\":\"failed\""))
    }

    @Test func pricePointsAreCachedForSevenDays() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(h.reader.calls.filter { $0 == "pricePoints:6500000001" }.count == 1)
        #expect(h.reader.calls.filter { $0 == "iapPricePoints:6600000001" }.count == 1)
        h.clock.advance(by: 8 * 86_400)
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(h.reader.calls.filter { $0 == "pricePoints:6500000001" }.count == 2)
        // A territory without points forces a refresh even inside the seven days.
        h.reader.update { $0.subscriptions[0].availableTerritories.insert("FRA") }
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(h.reader.calls.filter { $0 == "pricePoints:6500000001" }.count == 3)
    }

    @Test func aSecondChangeOfAnIAPScheduleAfterAnAckIsANewFinding() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update { $0.schedules["6600000001"] = Sample.schedule(prices: [("USA", "59.99")]) }
        let first = try #require(try await h.engine.sync(trigger: .manual, scope: .all).newFindings.first)
        try h.catalog.ack(findingId: first.id, reason: "Changed on purpose in App Store Connect", at: h.clock.now())
        h.reader.update { $0.schedules["6600000001"] = Sample.schedule(prices: [("USA", "69.99")]) }
        let second = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(second.newFindings.map(\.message) == ["IAP price schedule 6600000001 changed outside Purser"])
        #expect(second.newFindings.first?.id != first.id)
        #expect(try h.catalog.findings(includeAcked: false).map(\.id) == second.newFindings.map(\.id))
    }

    @Test func iapScheduleChangeIsExternal() async throws {
        let h = try Harness()
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update { $0.schedules["6600000001"] = Sample.schedule(prices: [("USA", "59.99")]) }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.message) == ["IAP price schedule 6600000001 changed outside Purser"])
        #expect(result.newFindings.first?.cell == .iapSchedule(iapId: "6600000001"))
    }

    @Test func requestCountComesFromTheReader() async throws {
        let h = try Harness()
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.requestCount == h.reader.calls.count)
        #expect(try h.syncRun(1)?.requests == h.reader.calls.count)
    }
}

extension Harness {
    /// "asc_id|owner_key|number|state" of every stored version, by asc id.
    func versionRows() throws -> [String] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM metadata_version ORDER BY asc_id").map { row -> String in
                let id: String = row["asc_id"], owner: String = row["owner_key"], number: Int = row["number"], state: String = row["state"]
                return "\(id)|\(owner)|\(number)|\(state)"
            }
        }
    }

    /// "asc_id|reference_name|first_sync|last_sync" of every stored group.
    func groupRows() throws -> [String] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM subscription_group ORDER BY asc_id").map { row -> String in
                let id: String = row["asc_id"], name: String = row["reference_name"], first: Int64 = row["first_sync"], last: Int64 = row["last_sync"]
                return "\(id)|\(name)|\(first)|\(last)"
            }
        }
    }
}

@Suite struct SyncEngineLocalizationTests {
    private static let yearly = LocalizationOwner.subscription("6500000001")
    private static let lifetime = LocalizationOwner.iap("6600000001")
    private static let premium = LocalizationOwner.group("7000000001")

    /// The base catalog with a live version 1 for the subscription (en-US, cs), the IAP (en-US) and the group (en-US).
    private static func script() -> ScriptedReader.Script {
        var script = Harness.baseScript()
        script.metadata[yearly] = OwnerMetadata(owner: yearly, versions: [Sample.version("sver-1", number: 1, state: .approved)], localizations: [
            Sample.text("sloc-1-en", version: "sver-1", name: "Fruit Yearly", description: "Fruit all year"),
            Sample.text("sloc-1-cs", version: "sver-1", locale: "cs", name: "Ovoce ročně", description: "Ovoce na celý rok"),
        ])
        script.metadata[lifetime] = OwnerMetadata(owner: lifetime, versions: [Sample.version("iver-1", owner: lifetime, number: 1, state: .approved)],
                                                  localizations: [Sample.text("iloc-1-en", owner: lifetime, version: "iver-1", name: "Fruit Lifetime",
                                                                              description: "Every fruit, forever")])
        script.metadata[premium] = OwnerMetadata(owner: premium, versions: [Sample.version("gver-1", owner: premium, number: 1, state: .approved)],
                                                 localizations: [Sample.text("gloc-1-en", owner: premium, version: "gver-1", name: "Fruit Premium",
                                                                             customAppName: "Fruit Journal")])
        return script
    }

    @Test func firstSyncStoresGroupsVersionsAndTextsOfEveryOwner() async throws {
        let h = try Harness(Self.script())
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.status == .complete)
        #expect(result.newFindings.isEmpty)
        #expect(h.reader.calls.filter { $0.hasPrefix("metadata:") } == ["metadata:S|6500000001", "metadata:I|6600000001", "metadata:G|7000000001"])
        #expect(try h.observations("LOCALIZATION").map(\.ascId) == ["sloc-1-cs", "sloc-1-en", "iloc-1-en", "gloc-1-en"])
        #expect(try h.observations("LOCALIZATION").allSatisfy { $0.provenance == "BASELINE" })
        #expect(try h.catalog.history(cell: .localization(owner: Self.yearly, locale: "cs")).map(\.ascId) == ["sloc-1-cs"])
        #expect(try h.versionRows() == ["gver-1|G|7000000001|1|APPROVED", "iver-1|I|6600000001|1|APPROVED", "sver-1|S|6500000001|1|APPROVED"])
        #expect(try h.groupRows() == ["7000000001|Fruit Premium|1|1"])

        h.reader.update { $0.groups = [ASCSubscriptionGroup(id: "7000000001", referenceName: "Fruit Premium 2")] }
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(try h.groupRows() == ["7000000001|Fruit Premium 2|1|2"])
    }

    @Test func aTextChangedInAppStoreConnectIsExternal() async throws {
        let h = try Harness(Self.script())
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update { $0.metadata[Self.yearly]?.localizations[1].text.name = "Fruit Yearly Plus" }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.type) == [.external])
        #expect(result.newFindings.first?.cell == .localization(owner: Self.yearly, locale: "en-US"))
        #expect(result.newFindings.first?.message == "Localization sloc-1-en changed outside Purser")
        #expect(try h.catalog.history(cell: .localization(owner: Self.yearly, locale: "en-US")).map(\.provenance) == [.baseline, .external])
    }

    @Test func aSecondEditOfATextAfterAnAckIsANewFinding() async throws {
        let h = try Harness(Self.script())
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update { $0.metadata[Self.yearly]?.localizations[1].text.name = "Fruit Yearly Plus" }
        let first = try #require(try await h.engine.sync(trigger: .manual, scope: .all).newFindings.first)
        try h.catalog.ack(findingId: first.id, reason: "Renamed on purpose in App Store Connect", at: h.clock.now())
        h.reader.update { $0.metadata[Self.yearly]?.localizations[1].text.name = "Fruit Yearly Max" }
        let second = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(second.newFindings.map(\.message) == ["Localization sloc-1-en changed outside Purser"])
        #expect(second.newFindings.first?.id != first.id)
        #expect(try h.catalog.findings(includeAcked: false).map(\.id) == second.newFindings.map(\.id))
    }

    @Test func approvalOfThePendingVersionRetiresTheOldTextsSilently() async throws {
        var script = Self.script()
        script.metadata[Self.yearly] = OwnerMetadata(owner: Self.yearly, versions: [
            Sample.version("sver-1", number: 1, state: .approved), Sample.version("sver-2", number: 2, state: .waitingForReview),
        ], localizations: [
            Sample.text("sloc-1-en", version: "sver-1", name: "Fruit Yearly", description: "Fruit all year"),
            Sample.text("sloc-2-en", version: "sver-2", name: "Fruit Yearly Plus", description: "All the fruit"),
        ])
        let h = try Harness(script)
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update {
            // The reader still returns the retired text; the sync keeps only texts of the live and the pending version.
            $0.metadata[Self.yearly]?.versions = [Sample.version("sver-1", number: 1, state: .replacedWithNewVersion),
                                                  Sample.version("sver-2", number: 2, state: .approved)]
        }
        let result = try await h.engine.sync(trigger: .nightly, scope: .all)
        #expect(result.newFindings.isEmpty)
        #expect(try h.observations("LOCALIZATION").first { $0.ascId == "sloc-1-en" }?.expired == 1)
        #expect(try h.observations("LOCALIZATION").first { $0.ascId == "sloc-2-en" }?.lastSync == 2)
        #expect(try h.versionRows().filter { $0.hasPrefix("sver") } == ["sver-1|S|6500000001|1|REPLACED_WITH_NEW_VERSION",
                                                                         "sver-2|S|6500000001|2|APPROVED"])
    }

    private static func withNewVersion(_ script: inout ScriptedReader.Script) {
        script.metadata[yearly]?.versions.append(Sample.version("sver-2", number: 2, state: .prepareForSubmission))
        script.metadata[yearly]?.localizations += [
            Sample.text("sloc-2-en", version: "sver-2", name: "Fruit Yearly", description: "Fruit all year"),
            Sample.text("sloc-2-cs", version: "sver-2", locale: "cs", name: "Ovoce ročně", description: "Ovoce na celý rok"),
        ]
    }

    @Test func aVersionCreatedInAppStoreConnectIsExternal() async throws {
        let h = try Harness(Self.script())
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update { Self.withNewVersion(&$0) }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.message).sorted() == ["Localization sloc-2-cs appeared outside Purser",
                                                               "Localization sloc-2-en appeared outside Purser"])
    }

    @Test func textsInAVersionPurserCreatedArePurser() async throws {
        let h = try Harness(Self.script())
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        // No localization payload exists before localization plans; the stand-in payload is never sent, only the asc id counts.
        try h.recordPurserItem(.deletePromo(ascId: "unused"), cell: .metadataVersion(owner: Self.yearly), state: .done, ascId: "sver-2")
        h.reader.update { Self.withNewVersion(&$0) }
        let result = try await h.engine.sync(trigger: .verify, scope: .products(["6500000001"]))
        #expect(result.newFindings.isEmpty)
        #expect(try h.observations("LOCALIZATION").filter { $0.ascId.hasPrefix("sloc-2") }.map(\.provenance) == ["PURSER", "PURSER"])
    }

    private static func setText(_ script: inout ScriptedReader.Script, _ ascId: String, _ text: LocalizationText) {
        guard let index = script.metadata[yearly]?.localizations.firstIndex(where: { $0.ascId == ascId }) else { return }
        script.metadata[yearly]?.localizations[index].text = text
    }

    private static let english = CellKey.localization(owner: yearly, locale: "en-US")
    private static let purserText = LocalizationText(name: "Fruit Yearly Plus", description: "Fruit all year")

    /// The base catalog with version 2 in preparation, after a Done PATCH of its en-US text that the verify sync saw.
    private static func afterPurserWroteEnglish() async throws -> Harness {
        var script = Self.script()
        Self.withNewVersion(&script)
        let h = try Harness(script)
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        try h.recordPurserItem(.setLocalization(SetLocalization(owner: yearly, locale: "en-US", text: purserText,
                                                                localizationId: "sloc-2-en", versionId: nil)),
                               cell: english, state: .done, ascId: "sloc-2-en")
        h.reader.update { Self.setText(&$0, "sloc-2-en", purserText) }
        let verified = try await h.engine.sync(trigger: .verify, scope: .products(["6500000001"]))
        #expect(verified.newFindings.isEmpty)
        #expect(try h.catalog.history(cell: english).filter { $0.ascId == "sloc-2-en" }.map(\.provenance) == [.baseline, .purser])
        return h
    }

    @Test func anEditInAppStoreConnectOfATextPurserWroteIsExternal() async throws {
        let h = try await Self.afterPurserWroteEnglish()
        h.reader.update { Self.setText(&$0, "sloc-2-en", LocalizationText(name: "Fruit Yearly Plus", description: "Edited in App Store Connect")) }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.message) == ["Localization sloc-2-en changed outside Purser"])
        #expect(try h.catalog.history(cell: Self.english).filter { $0.ascId == "sloc-2-en" }.map(\.provenance)
                == [.baseline, .purser, .external])
    }

    @Test func aTextPurserWroteThatGoesBackToItsEarlierFormOutsidePurserIsExternal() async throws {
        let h = try await Self.afterPurserWroteEnglish()
        h.reader.update { Self.setText(&$0, "sloc-2-en", LocalizationText(name: "Fruit Yearly", description: "Fruit all year")) }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.message) == ["Localization sloc-2-en went back to an earlier form outside Purser"])
    }

    @Test func anEditInAppStoreConnectOfATextInAVersionPurserCreatedIsExternal() async throws {
        let h = try Harness(Self.script())
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        try h.recordPurserItem(.deletePromo(ascId: "unused"), cell: .metadataVersion(owner: Self.yearly), state: .done, ascId: "sver-2")
        h.reader.update { Self.withNewVersion(&$0) }
        #expect(try await h.engine.sync(trigger: .verify, scope: .products(["6500000001"])).newFindings.isEmpty)
        h.reader.update { Self.setText(&$0, "sloc-2-cs", LocalizationText(name: "Ovoce ročně", description: "Upraveno v App Store Connect")) }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.message) == ["Localization sloc-2-cs changed outside Purser"])
    }

    @Test func aLocaleRemovedFromACurrentVersionIsExternal() async throws {
        let h = try Harness(Self.script())
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update { $0.metadata[Self.yearly]?.localizations.removeAll { $0.locale == "cs" } }
        let result = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(result.newFindings.map(\.message) == ["Localization sloc-1-cs disappeared outside Purser"])
        #expect(result.newFindings.first?.cell == .localization(owner: Self.yearly, locale: "cs"))
    }

    @Test func theSnapshotCarriesGroupsVersionsAndTexts() async throws {
        let h = try Harness(Self.script())
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        let snapshot = try #require(try h.catalog.latestSnapshot())
        #expect(snapshot.groups == ["7000000001": SubscriptionGroupInfo(ascId: "7000000001", referenceName: "Fruit Premium")])
        #expect(snapshot.metadata.keys.sorted() == [Self.premium, Self.lifetime, Self.yearly])
        #expect(snapshot.metadata[Self.yearly] == Self.script().metadata[Self.yearly])
        #expect(snapshot.ownerName(Self.premium) == "Fruit Premium")
        #expect(snapshot.cellState(.localization(owner: Self.yearly, locale: "cs"), on: CalendarDate(year: 2026, month: 10, day: 9))
                == .localization(live: Self.script().metadata[Self.yearly]?.localizations.first, pending: nil, pendingVersion: nil))

        // A product that leaves the catalog takes its texts with it.
        h.reader.update { $0.iaps = [] }
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(try h.catalog.latestSnapshot()?.metadata[Self.lifetime] == nil)
    }

    @Test func aFailedReadKeepsTheVersionsAndTextsOfTheLastCompleteRead() async throws {
        let h = try Harness(Self.script())
        _ = try await h.engine.sync(trigger: .manual, scope: .all)
        h.reader.update {
            $0.metadata[Self.yearly]?.versions = [Sample.version("sver-1", number: 1, state: .replacedWithNewVersion)]
            $0.failures["metadata:S|6500000001"] = .network(description: "offline", maybeSent: false)
        }
        let result = try await h.engine.sync(trigger: .nightly, scope: .all)
        #expect(result.status == .partial)
        #expect(result.newFindings.isEmpty)
        #expect(try h.syncRun(2)?.scopes.contains("6500000001|LOCALIZATION") == false)
        #expect(try h.versionRows().contains("sver-1|S|6500000001|1|APPROVED"))
        let texts = try h.catalog.liveObservations(productAscId: "6500000001").filter { $0.kind == "LOCALIZATION" }
        #expect(texts.map(\.ascId) == ["sloc-1-cs", "sloc-1-en"])
        #expect(texts.map(\.lastSync) == [1, 1])
        #expect(try h.catalog.latestSnapshot()?.liveVersion(of: Self.yearly)?.state == .approved)
    }

    @Test func aPartialSyncNamesItsFailedScopes() async throws {
        let h = try Harness(Self.script())
        let complete = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(complete.failedScopes.isEmpty)
        h.reader.update {
            $0.failures["metadata:S|6500000001"] = .network(description: "offline", maybeSent: false)
            $0.failures["introductoryOffers:6500000001"] = .network(description: "offline", maybeSent: false)
        }
        let partial = try await h.engine.sync(trigger: .nightly, scope: .all)
        #expect(partial.status == .partial)
        #expect(partial.failedScopes == ["6500000001|LOCALIZATION", "6500000001|INTRO"])
    }

    @Test func aPartialSyncNamesAFailedPricePointRead() async throws {
        let h = try Harness(Self.script())
        h.reader.update { $0.failures["pricePoints:6500000001"] = .network(description: "offline", maybeSent: false) }
        let partial = try await h.engine.sync(trigger: .manual, scope: .all)
        #expect(partial.failedScopes == ["6500000001|PRICE_POINTS"])
    }
}

@Suite struct SyncResultCompletenessTests {
    private static let yearly = CellKey.regular(subscriptionId: "sub-y", territory: "CZE", planType: .upfront)
    private static let intro = CellKey.intro(subscriptionId: "sub-y", territory: "CZE", planType: .upfront)
    private static let promo = CellKey.promo(subscriptionId: "sub-y", offerCode: "winter_v1")
    private static let schedule = CellKey.iapSchedule(iapId: "iap-life")
    private static let text = CellKey.localization(owner: .subscription("sub-y"), locale: "cs")
    private static let version = CellKey.metadataVersion(owner: .group("grp-1"))

    private static func result(_ failed: Set<String>) -> SyncResult {
        SyncResult(syncId: 2, status: failed.isEmpty ? .complete : .partial, requestCount: 10, newFindings: [], failedScopes: failed)
    }

    @Test func aCompleteSyncIsCompleteForEveryCell() {
        #expect(Self.result([]).isComplete(for: [Self.yearly, Self.text, Self.version]))
    }

    @Test func priceCellsNeedEveryPriceScopeOfTheirProductButNotItsTexts() {
        for kind in ["PRICE", "INTRO", "PROMO", "PRICE_POINTS"] {
            for cell in [Self.yearly, Self.intro, Self.promo] {
                #expect(!Self.result(["sub-y|\(kind)"]).isComplete(for: [cell]), "\(kind) blocks \(cell)")
            }
        }
        #expect(!Self.result(["iap-life|IAP_SCHEDULE"]).isComplete(for: [Self.schedule]))
        #expect(!Self.result(["iap-life|PRICE_POINTS"]).isComplete(for: [Self.schedule]))
        #expect(Self.result(["sub-y|LOCALIZATION"]).isComplete(for: [Self.yearly, Self.intro, Self.promo]))
        #expect(Self.result(["iap-life|LOCALIZATION"]).isComplete(for: [Self.schedule]))
        #expect(Self.result(["sub-m|PRICE"]).isComplete(for: [Self.yearly]))
    }

    @Test func textAndVersionCellsNeedOnlyTheirOwnersTexts() {
        #expect(!Self.result(["sub-y|LOCALIZATION"]).isComplete(for: [Self.text]))
        #expect(!Self.result(["grp-1|LOCALIZATION"]).isComplete(for: [Self.version]))
        #expect(Self.result(["sub-y|PRICE", "sub-y|PRICE_POINTS"]).isComplete(for: [Self.text]))
        #expect(Self.result(["sub-m|LOCALIZATION"]).isComplete(for: [Self.text, Self.version]))
    }

    @Test func aMixedPlanNeedsBoth() {
        #expect(!Self.result(["sub-y|LOCALIZATION"]).isComplete(for: [Self.yearly, Self.text]))
        #expect(!Self.result(["sub-y|PRICE"]).isComplete(for: [Self.yearly, Self.text]))
    }

    @Test func anIncompleteResultWithoutNamedScopesIsNeverComplete() {
        let unnamed = SyncResult(syncId: 2, status: .partial, requestCount: 10, newFindings: [], failedScopes: [])
        #expect(!unnamed.isComplete(for: [Self.yearly]))
        #expect(!unnamed.isComplete(for: []))
        #expect(!Self.result(["no-separator"]).isComplete(for: [Self.yearly]))
    }
}
