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

/// Touch ID that always succeeds and counts how often it was asked.
private actor CountingGate: BiometricGate {
    private(set) var count = 0
    func authenticate(reason: String) async throws { count += 1 }
}

private func spikeHarness(isProduction: Bool = false) async throws -> ExecutorHarness {
    try await ExecutorHarness.make(model: FakeSeed.fruitJarWithSpikeGroup(), isProduction: isProduction)
}

/// A write-capable client that shares the harness AppGuard and RateBudget (as WorkspaceSession+SpikeProbe does).
private func probe(_ h: ExecutorHarness, gate: CountingGate) async throws -> SpikeProbe {
    let http = try await WriteTestClients.http(transport: h.fake, readOnly: false, products: [], budget: h.budget,
                                               appGuard: h.appGuard, now: h.clock.nowFunction)
    return SpikeProbe(config: h.config, http: http, reader: h.reader, catalog: h.catalog, plans: h.store, audit: h.audit,
                      budget: h.budget, gate: gate, now: h.clock.nowFunction)
}

private func payload(_ event: AuditEvent) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8))) as? [String: Any]) ?? [:]
}

private let futurePrice = """
{"data":{"type":"subscriptionPrices","attributes":{"startDate":"2026-11-20","preserveCurrentPrice":true,"planType":"UPFRONT"},
 "relationships":{"subscription":{"data":{"type":"subscriptions","id":"sub-spike-a"}},
  "subscriptionPricePoint":{"data":{"type":"subscriptionPricePoints","id":"pp-sub-spike-a-USA-12"}},
  "territory":{"data":{"type":"territories","id":"USA"}}}}}
"""

private func request(_ step: String, _ method: String, _ path: String, query: String = "", body: String? = nil) -> SpikeRequest {
    SpikeRequest(spikeId: String(step.prefix { $0 != "-" }), step: step, method: method, path: path, query: query,
                 body: body.map { Data($0.utf8) })
}

@Suite("Spike probe")
struct SpikeProbeTests {
    @Test func refusesAProductionWorkspaceBeforeAnyRequest() async throws {
        let h = try await spikeHarness(isProduction: true)
        let gate = CountingGate()
        await #expect(throws: SpikeProbeError.productionWorkspace) {
            _ = try await probe(h, gate: gate).send(request("S2-1", "POST", "/v1/subscriptionPrices", body: futurePrice))
        }
        #expect(await h.fake.requests().isEmpty)
        #expect(await gate.count == 0)
    }

    @Test func refusesWhileAPlanIsApplying() async throws {
        let h = try await spikeHarness()
        _ = try await h.initialSync()
        let applying = try h.insertPlan(items: [], state: .applying)
        await #expect(throws: SpikeProbeError.anotherPlanApplying(applying)) {
            _ = try await probe(h, gate: CountingGate()).send(request("S2-1", "POST", "/v1/subscriptionPrices", body: futurePrice))
        }
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func refusesUnknownMethodsAndMalformedPaths() async throws {
        let h = try await spikeHarness()
        _ = try await h.initialSync()
        let p = try await probe(h, gate: CountingGate())
        await #expect(throws: SpikeProbeError.methodNotAllowed("PUT")) { _ = try await p.send(request("S2-1", "PUT", "/v1/subscriptionPrices")) }
        await #expect(throws: SpikeProbeError.invalidPath("/v1/../apps")) { _ = try await p.send(request("S2-1", "GET", "/v1/../apps")) }
        await #expect(throws: SpikeProbeError.invalidPath("/v1//apps")) { _ = try await p.send(request("S2-1", "GET", "/v1//apps")) }
        await #expect(throws: SpikeProbeError.invalidPath("/v1/territories?limit=2")) {
            _ = try await p.send(request("S2-1", "GET", "/v1/territories?limit=2"))
        }
        await #expect(throws: SpikeProbeError.invalidPath("/apps")) { _ = try await p.send(request("S2-1", "GET", "/apps")) }
    }

    @Test func refusesIdsOutsideTheSpikeGroupForReadsAndWrites() async throws {
        let h = try await spikeHarness()
        _ = try await h.initialSync()
        let gate = CountingGate()
        let p = try await probe(h, gate: gate)
        await #expect(throws: SpikeProbeError.idNotAllowed("price-sub-y-USA-0")) {
            _ = try await p.send(request("S2-9", "DELETE", "/v1/subscriptionPrices/price-sub-y-USA-0"))
        }
        let foreignBody = futurePrice.replacingOccurrences(of: "\"sub-spike-a\"", with: "\"sub-y\"")
        await #expect(throws: SpikeProbeError.idNotAllowed("sub-y")) {
            _ = try await p.send(request("S2-1", "POST", "/v1/subscriptionPrices", body: foreignBody))
        }
        await #expect(throws: SpikeProbeError.idNotAllowed("sub-y")) {
            _ = try await p.send(request("S2-3", "GET", "/v1/subscriptions/sub-y/prices"))
        }
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(await gate.count == 0)
    }

    @Test func writeNeedsTouchIDAndIsAuditedBeforeAndAfterWithTheTokenId() async throws {
        let h = try await spikeHarness()
        _ = try await h.initialSync()
        let gate = CountingGate()
        let p = try await probe(h, gate: gate)
        let created = try await p.send(request("S2-7", "POST", "/v1/subscriptionPrices", body: futurePrice))
        #expect(created.status == 201)
        let newId = try #require(created.createdIds.first)
        #expect(try await p.allowedIds().contains(newId))
        let deleted = try await p.send(request("S2-9", "DELETE", "/v1/subscriptionPrices/\(newId)"))
        #expect(deleted.status == 204)
        #expect(await gate.count == 2)
        let events = try h.audit.events(after: 0, limit: 100_000).filter { $0.refs["spike"] == "S2" }
        #expect(events.map(\.type) == [.httpSent, .httpReceived, .httpSent, .httpReceived])
        #expect(events.map { $0.refs["step"] } == ["S2-7", "S2-7", "S2-9", "S2-9"])
        let sent = payload(events[0])
        #expect(sent["method"] as? String == "POST")
        #expect(sent["path"] as? String == "/v1/subscriptionPrices")
        #expect(sent["keyId"] as? String == "TESTKEY001")
        let tokenIds = [events[0], events[2]].compactMap { payload($0)["jti"] as? String }
        #expect(tokenIds.count == 2)
        #expect(await h.fake.writeRequests().compactMap { $0.tokenId } == tokenIds)
        #expect(payload(events[1])["status"] as? Int == 201)
        #expect(events.allSatisfy { !$0.payloadJSON.contains("Bearer") && !$0.payloadJSON.contains("eyJ") })
    }

    @Test func readNeedsNoTouchIDAllowsTheAppIdAndKeepsOnlyTheBodySize() async throws {
        let h = try await spikeHarness()
        _ = try await h.initialSync()
        let gate = CountingGate()
        let response = try await probe(h, gate: gate).send(request("S2-3", "GET", "/v1/apps/\(FakeSeed.appId)/subscriptionGroups",
                                                                   query: "limit=200"))
        #expect(response.status == 200)
        #expect(response.createdIds.isEmpty)
        #expect(await gate.count == 0)
        let received = try #require(try h.audit.events(after: 0, limit: 100_000).last)
        #expect(received.type == .httpReceived)
        #expect(payload(received)["bodyBytes"] as? Int == response.body.count)
        #expect(payload(received)["body"] == nil)
    }

    @Test func non2xxIsReturnedAndAuditedInsteadOfThrown() async throws {
        let h = try await spikeHarness()
        _ = try await h.initialSync()
        let p = try await probe(h, gate: CountingGate())
        _ = try await p.send(request("S6-1", "POST", "/v1/subscriptionPrices", body: futurePrice))
        let second = try await p.send(request("S6-2", "POST", "/v1/subscriptionPrices",
                                              body: futurePrice.replacingOccurrences(of: "pp-sub-spike-a-USA-12", with: "pp-sub-spike-a-USA-13")))
        #expect(second.status == 409)
        #expect(String(decoding: second.body, as: UTF8.self).contains("Must delete future price change"))
        #expect(second.createdIds.isEmpty)
        let received = try #require(try h.audit.events(after: 0, limit: 100_000).last)
        #expect(payload(received)["status"] as? Int == 409)
    }

    @Test func bindingMismatchStopsTheRequest() async throws {
        let h = try await spikeHarness()
        _ = try await h.initialSync()
        await h.fake.mutate { $0.app.bundleId = "com.example.other" }
        await #expect(throws: SpikeProbeError.bindingMismatch("\(FakeSeed.appId) com.example.other")) {
            _ = try await probe(h, gate: CountingGate()).send(request("S2-1", "POST", "/v1/subscriptionPrices", body: futurePrice))
        }
        #expect(await h.fake.writeRequests().isEmpty)
    }

    @Test func transportErrorIsAuditedWithNullStatusAndRethrown() async throws {
        let h = try await spikeHarness()
        _ = try await h.initialSync()
        await h.fake.inject(.networkBeforeSend)
        await #expect(throws: ASCError.self) {
            _ = try await probe(h, gate: CountingGate()).send(request("S5-1", "POST", "/v1/subscriptionPrices", body: futurePrice))
        }
        let last = try #require(try h.audit.events(after: 0, limit: 100_000).last)
        #expect(last.type == .httpReceived)
        #expect(last.payloadJSON.contains("\"status\":null"))
        #expect(payload(last)["error"] != nil)
    }

    @Test func variablesComeFromTheSpikeGroupInTheCatalog() async throws {
        let h = try await spikeHarness()
        let snapshot = try await h.initialSync()
        let values = SpikeVariables.catalog(snapshot: snapshot, config: h.config, today: h.today)
        #expect(values["APP_ID"] == FakeSeed.appId)
        #expect(values["SPIKE_GROUP"] == "grp-spike")
        #expect(values["SPIKE_YEARLY_A"] == "sub-spike-a")
        #expect(values["SPIKE_YEARLY_B"] == nil)
        #expect(values["PP_YA_USA_LOW"] == "pp-sub-spike-a-USA-4")
        #expect(values["PP_YA_USA_MID"] == "pp-sub-spike-a-USA-14")
        #expect(values["PP_YA_USA_HIGH"] == "pp-sub-spike-a-USA-24")
        #expect(values["PRICE_YA_USA"] == "price-sub-spike-a-USA-0")
        #expect(values["CURPP_YA_USA"] == "pp-sub-spike-a-USA-9")
        #expect(values["ABOVEPP_YA_USA"] == "pp-sub-spike-a-USA-10")
        #expect(values["SPIKE_LIFETIME"] == "iap-spike")
        #expect(values["SPIKE_SCHEDULE"] == "iap-spike")
        #expect(SpikeVariables.catalog(snapshot: nil, config: h.config, today: h.today) == ["APP_ID": FakeSeed.appId])
    }

    @Test func substitutionResolvesNestedDatesAndRejectsUnknownNames() throws {
        let today = CalendarDate(iso: "2026-10-09")!
        let variables = try SpikeVariables.parse("START=\"{{TODAY+7}}\"\n# comment\nSUB=sub-spike-a\n")
        #expect(try SpikeVariables.substitute(#"{"startDate": {{START}}, "id": "{{SUB}}", "end": "{{TODAY-1}}"}"#,
                                              variables: variables, today: today)
                == #"{"startDate": "2026-10-16", "id": "sub-spike-a", "end": "2026-10-08"}"#)
        #expect(throws: SpikeVariableError.unknown(["{{NOPE}}"])) {
            try SpikeVariables.substitute("/v1/subscriptions/{{NOPE}}/prices", variables: variables, today: today)
        }
        #expect(throws: SpikeVariableError.malformedLine("JUSTTEXT")) { try SpikeVariables.parse("JUSTTEXT") }
    }
}
