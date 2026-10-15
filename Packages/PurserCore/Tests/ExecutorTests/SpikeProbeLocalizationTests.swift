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

private func request(_ step: String, _ method: String, _ path: String, body: String? = nil) -> SpikeRequest {
    SpikeRequest(spikeId: String(step.prefix { $0 != "-" }), step: step, method: method, path: path, query: "",
                 body: body.map { Data($0.utf8) })
}

private func createBody(version: String, locale: String, name: String) -> String {
    #"{"data":{"type":"subscriptionLocalizations","attributes":{"locale":"\#(locale)","name":"\#(name)"},"relationships":{"version":{"data":{"type":"subscriptionVersions","id":"\#(version)"}}}}}"#
}

private func patchBody(_ id: String, name: String) -> String {
    #"{"data":{"type":"subscriptionLocalizations","id":"\#(id)","attributes":{"name":"\#(name)"}}}"#
}

private func versionBody(_ subscription: String) -> String {
    #"{"data":{"type":"subscriptionVersions","relationships":{"subscription":{"data":{"type":"subscriptions","id":"\#(subscription)"}}}}}"#
}

@Suite("Spike probe localizations")
struct SpikeProbeLocalizationTests {
    @Test func allowedIdsCoverTheSpikeVersionsAndTextsOnly() async throws {
        let h = try await spikeHarness()
        let snapshot = try await h.initialSync()
        let allowed = try await probe(h, gate: CountingGate()).allowedIds()
        for owner in [LocalizationOwner.subscription("sub-spike-a"), .group("grp-spike"), .iap("iap-spike")] {
            let metadata = try #require(snapshot.metadata[owner])
            #expect(!metadata.versions.isEmpty)
            #expect(metadata.versions.allSatisfy { allowed.contains($0.ascId) })
            #expect(metadata.localizations.allSatisfy { allowed.contains($0.ascId) })
        }
        let foreign = try #require(snapshot.metadata[.subscription("sub-y")])
        #expect(!foreign.versions.contains { allowed.contains($0.ascId) })
        #expect(!foreign.localizations.contains { allowed.contains($0.ascId) })
    }

    @Test func textsAndVersionsOfOtherProductsAreRefusedBeforeTouchID() async throws {
        let h = try await spikeHarness()
        let snapshot = try await h.initialSync()
        let gate = CountingGate()
        let p = try await probe(h, gate: gate)
        let live = try #require(snapshot.liveVersion(of: .subscription("sub-y")))
        let row = try #require(snapshot.localization(.subscription("sub-y"), locale: "en-US", versionId: live.ascId))
        await #expect(throws: SpikeProbeError.idNotAllowed(row.ascId)) {
            _ = try await p.send(request("SL10n-90", "PATCH", "/v2/subscriptionLocalizations/\(row.ascId)", body: patchBody(row.ascId, name: "X")))
        }
        await #expect(throws: SpikeProbeError.idNotAllowed(live.ascId)) {
            _ = try await p.send(request("SL10n-91", "POST", "/v2/subscriptionLocalizations", body: createBody(version: live.ascId, locale: "de-DE", name: "Obst")))
        }
        await #expect(throws: SpikeProbeError.idNotAllowed("sub-y")) {
            _ = try await p.send(request("SL10n-92", "POST", "/v1/subscriptionVersions", body: versionBody("sub-y")))
        }
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(await gate.count == 0)
    }

    @Test func aSpikeTextIsPatchedWithTouchIDAndAudit() async throws {
        let h = try await spikeHarness()
        let snapshot = try await h.initialSync()
        let gate = CountingGate()
        let owner = LocalizationOwner.subscription("sub-spike-a")
        let version = try #require(snapshot.pendingVersion(of: owner))
        let row = try #require(snapshot.localization(owner, locale: "en-US", versionId: version.ascId))
        let response = try await probe(h, gate: gate).send(request("SL10n-6", "PATCH", "/v2/subscriptionLocalizations/\(row.ascId)",
                                                                   body: patchBody(row.ascId, name: "Spike Yearly A2")))
        #expect(response.status == 200)
        #expect(await gate.count == 1)
        let model = await h.fake.model
        #expect(model.localizations.first { $0.id == row.ascId }?.text.name == "Spike Yearly A2")
        let events = try h.audit.events(after: 0, limit: 100_000).filter { $0.refs["spike"] == "SL10n" }
        #expect(events.map(\.type) == [.httpSent, .httpReceived])
    }

    @Test func aVersionPostForASpikeProductPassesTheProbeAndAppGuard() async throws {
        let h = try await spikeHarness()
        _ = try await h.initialSync()
        let gate = CountingGate()
        _ = try await probe(h, gate: gate).send(request("SL10n-8", "POST", "/v1/subscriptionVersions", body: versionBody("sub-spike-a")))
        #expect(await h.fake.writeRequests().map(\.path) == ["/v1/subscriptionVersions"])
        #expect(await gate.count == 1)
    }

    @Test func variablesNameTheSpikeVersionsAndTexts() async throws {
        let h = try await spikeHarness()
        let snapshot = try await h.initialSync()
        let values = SpikeVariables.catalog(snapshot: snapshot, config: h.config, today: h.today)
        #expect(values["VER_YA"] == "ver-spike-sub-spike-a-1")
        #expect(values["LOC_YA_EN_US"] == "loc-spike-sub-spike-a-en-US")
        #expect(values["VER_GROUP"] == "ver-spike-grp-spike-1")
        #expect(values["LOC_GROUP_EN_US"] == "loc-spike-grp-spike-en-US")
        #expect(values["VER_LIFE"] == "ver-spike-iap-spike-1")
        #expect(values["LOC_LIFE_EN_US"] == "loc-spike-iap-spike-en-US")
    }

    /// L-D4: no locale is ever removed. The probe's allowlist knows the id, so the refusal comes from AppGuard (rule for v2
    /// localizations), and nothing reaches App Store Connect.
    @Test func aDeleteOfASpikeTextIsRefusedAndNothingIsWritten() async throws {
        let h = try await spikeHarness()
        let snapshot = try await h.initialSync()
        let owner = LocalizationOwner.subscription("sub-spike-a")
        let version = try #require(snapshot.pendingVersion(of: owner))
        let row = try #require(snapshot.localization(owner, locale: "en-US", versionId: version.ascId))
        let path = "/v2/subscriptionLocalizations/\(row.ascId)"
        let p = try await probe(h, gate: CountingGate())
        #expect(try await p.allowedIds().contains(row.ascId))
        await #expect(throws: ASCError.foreignResource(path)) {
            _ = try await p.send(request("SL10n-93", "DELETE", path))
        }
        #expect(await h.fake.writeRequests().isEmpty)
        #expect(await h.fake.model.localizations.contains { $0.id == row.ascId })
    }
}
