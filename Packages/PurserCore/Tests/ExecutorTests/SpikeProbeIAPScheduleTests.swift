import Foundation
import Testing
import Domain
import Store
import Audit
import PurserSecurity
import ASCClient
import Catalog
@testable import Executor
import PurserTestSupport

private actor CountingGate: BiometricGate {
    private(set) var count = 0
    func authenticate(reason: String) async throws { count += 1 }
}

private func spikeHarness() async throws -> ExecutorHarness {
    try await ExecutorHarness.make(model: FakeSeed.fruitJarWithSpikeGroup())
}

private func probe(_ h: ExecutorHarness, gate: CountingGate) async throws -> SpikeProbe {
    let http = try await WriteTestClients.http(transport: h.fake, readOnly: false, products: [], budget: h.budget,
                                               appGuard: h.appGuard, now: h.clock.nowFunction)
    return SpikeProbe(config: h.config, http: http, reader: h.reader, catalog: h.catalog, plans: h.store, audit: h.audit,
                      budget: h.budget, gate: gate, now: h.clock.nowFunction)
}

/// docs/spikes/bodies/<name>, the templates the Spike console loads with "Load template…".
private func template(_ name: String) throws -> String {
    let url = RepoFiles.packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/spikes/bodies").appendingPathComponent(name)
    return try String(contentsOf: url, encoding: .utf8)
}

/// The template resolved the way the console does it: catalog variables, overridden by the user's NAME=value lines.
private func resolve(_ name: String, _ userLines: String, snapshot: CatalogSnapshot, h: ExecutorHarness) throws -> Data {
    let variables = SpikeVariables.catalog(snapshot: snapshot, config: h.config, today: h.today)
        .merging(try SpikeVariables.parse(userLines)) { _, user in user }
    return Data(try SpikeVariables.substitute(try template(name), variables: variables, today: h.today).utf8)
}

private func post(_ step: String, _ body: Data) -> SpikeRequest {
    SpikeRequest(spikeId: "S10", step: step, method: "POST", path: "/v1/inAppPurchasePriceSchedules", query: "", body: body)
}

/// Spike S10 (docs/spikes/S10.md): the variables and templates of the IAP schedule steps; these tests check that the steps
/// can be sent. FakeASC's answers to the POST follow the spike (FakeASCSpikeAlignmentTests).
@Suite("Spike probe IAP schedule (S10)")
struct SpikeProbeIAPScheduleTests {
    @Test func variablesNameTheSpikeIAPLadderAndManualPrices() async throws {
        let h = try await spikeHarness()
        let snapshot = try await h.initialSync()
        let values = SpikeVariables.catalog(snapshot: snapshot, config: h.config, today: h.today)
        #expect(values["SPIKE_BASE"] == "USA")
        #expect(values["PP_LIFE_USA_LOW"] == "pp-iap-spike-USA-4")
        #expect(values["PP_LIFE_USA_MID"] == "pp-iap-spike-USA-14")
        #expect(values["PP_LIFE_GBR_HIGH"] == "pp-iap-spike-GBR-24")
        #expect(values["MANUAL_LIFE_USA"] == "iapprice-iap-spike-USA-pp-iap-spike-USA-29-0-0")
        #expect(values["CURPP_LIFE_USA"] == "pp-iap-spike-USA-29")
        #expect(values["ABOVEPP_LIFE_USA"] == "pp-iap-spike-USA-30")
        #expect(values["MANUAL_LIFE_GBR"] == nil)
        #expect(values["SCHED_LIFE_USA"] == nil)
    }

    @Test func theS10TemplatesResolveFullyAndPassTheProbe() async throws {
        let h = try await spikeHarness()
        var snapshot = try await h.initialSync()
        let gate = CountingGate()
        let spike = try await probe(h, gate: gate)
        let common = "IAP={{SPIKE_LIFETIME}}\nBASE={{SPIKE_BASE}}\n"

        // S10-3: base USA, manual prices today in USA and GBR.
        let twoNow = try resolve("s10-iap-schedule-two-now.json", common + "LP_1={{PP_LIFE_USA_MID}}\nLP_2={{PP_LIFE_GBR_MID}}",
                                 snapshot: snapshot, h: h)
        #expect(try await spike.send(post("S10-3", twoNow)).status == 201)
        snapshot = try await h.initialSync()
        var values = SpikeVariables.catalog(snapshot: snapshot, config: h.config, today: h.today)
        #expect(values["CURPP_LIFE_USA"] == "pp-iap-spike-USA-14")
        #expect(values["CURPP_LIFE_GBR"] == "pp-iap-spike-GBR-14")

        // S10-6: a today price and a future one in USA.
        let nowAndFuture = try resolve("s10-iap-schedule-now-and-future.json",
                                       common + "LP_1={{PP_LIFE_USA_MID}}\nLP_2={{PP_LIFE_USA_HIGH}}\nSTART={{TODAY+30}}",
                                       snapshot: snapshot, h: h)
        #expect(String(decoding: nowAndFuture, as: UTF8.self).contains(#""startDate": "\#(h.today.adding(days: 30).iso)""#))
        #expect(try await spike.send(post("S10-6", nowAndFuture)).status == 201)
        snapshot = try await h.initialSync()
        values = SpikeVariables.catalog(snapshot: snapshot, config: h.config, today: h.today)
        #expect(values["SCHED_LIFE_USA"] != nil)

        // S10-9: a single price today in USA.
        let oneNow = try resolve("s10-iap-schedule-one-now.json", common + "LP_1={{PP_LIFE_USA_LOW}}", snapshot: snapshot, h: h)
        #expect(try await spike.send(post("S10-9", oneNow)).status == 201)

        #expect(await gate.count == 3)
        #expect(await h.fake.writeRequests().map(\.path) == Array(repeating: "/v1/inAppPurchasePriceSchedules", count: 3))
        let events = try h.audit.events(after: 0, limit: 100_000).filter { $0.refs["spike"] == "S10" }
        #expect(events.map(\.type) == [.httpSent, .httpReceived, .httpSent, .httpReceived, .httpSent, .httpReceived])
    }

    @Test func aScheduleForAnIAPOutsideTheSpikeGroupIsRefusedBeforeTouchID() async throws {
        let h = try await spikeHarness()
        let snapshot = try await h.initialSync()
        let gate = CountingGate()
        let body = try resolve("s10-iap-schedule-one-now.json", "IAP=iap-life\nBASE=USA\nLP_1=pp-iap-life-USA-14",
                               snapshot: snapshot, h: h)
        // The body names iap-life and its price point; either may be the first id refused.
        do {
            _ = try await probe(h, gate: gate).send(post("S10-x", body))
            Issue.record("expected the probe to refuse an IAP outside the spike group")
        } catch let SpikeProbeError.idNotAllowed(id) {
            #expect(["iap-life", "pp-iap-life-USA-14"].contains(id))
        }
        #expect(await gate.count == 0)
        #expect(await h.fake.writeRequests().isEmpty)
    }
}
