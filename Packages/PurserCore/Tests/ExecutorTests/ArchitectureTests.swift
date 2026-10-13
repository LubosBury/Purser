import Foundation
import Testing
import Domain
import Store
import Audit
import ASCClient
@testable import Executor
import PurserTestSupport

/// .../Packages/PurserCore/Tests/ExecutorTests/ArchitectureTests.swift -> .../Packages/PurserCore
private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()

/// An awaited call of an ASCWriting method. WritePayload cases share the names but are never awaited.
private let writeCallPattern = #"(?:try\s+)?await\s+[\w.?!\[\]()]*\.(createRegularPrice|deleteRegularPrice|createIntroductoryOffer|endIntroductoryOffer|deleteIntroductoryOffer|createPromotionalOffer|replacePromotionalOfferPrices|deletePromotionalOffer|replaceIAPPriceSchedule)\("#

/// The only files that may build a write-capable ASCHTTPClient (K11).
private let writeClientFiles = ["App/Session/WorkspaceSession+Apply.swift", "App/Session/WorkspaceSession+SpikeProbe.swift",
                                "App/Session/WorkspaceSession+ApprovedProbe.swift"]

private let scannedRoots = [packageRoot.appending(path: "Sources"), repoRoot.appending(path: "App"), repoRoot.appending(path: "LoginItem")]

private func swiftFiles(under directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private func relative(_ url: URL) -> String {
    String(url.standardizedFileURL.path.dropFirst(repoRoot.standardizedFileURL.path.count + 1))
}

private func codeLines(_ url: URL) throws -> [(number: Int, text: String)] {
    try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated()
        .map { (number: $0.offset + 1, text: $0.element) }
        .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
}

@Suite("Architecture and safety")
struct ArchitectureTests {
    @Test func scannedSourcesExist() {
        #expect(!swiftFiles(under: packageRoot.appending(path: "Sources")).isEmpty)
        #expect(!swiftFiles(under: repoRoot.appending(path: "App")).isEmpty)
    }

    @Test func ascWritesAreCalledOnlyFromExecutorAndASCClient() throws {
        let writeCall = try NSRegularExpression(pattern: writeCallPattern)
        var violations: [String] = []
        for root in scannedRoots {
            for file in swiftFiles(under: root) {
                let path = relative(file)
                if path.hasPrefix("Packages/PurserCore/Sources/Executor/") || path.hasPrefix("Packages/PurserCore/Sources/ASCClient/") { continue }
                for line in try codeLines(file) {
                    let range = NSRange(line.text.startIndex..., in: line.text)
                    if let match = writeCall.firstMatch(in: line.text, range: range), let name = Range(match.range(at: 1), in: line.text) {
                        violations.append("\(path):\(line.number) calls \(line.text[name])(")
                    }
                    if line.text.contains(".send(method:") || line.text.contains(".delete(path:") || line.text.contains(".sendRaw(") {
                        violations.append("\(path):\(line.number) writes through ASCHTTPClient")
                    }
                }
            }
        }
        #expect(violations.isEmpty, "ASC writes outside Sources/Executor: \(violations)")
    }

    @Test func writeCapableClientIsBuiltOnlyInTheAllowedSessionFiles() throws {
        var hits: [String] = []
        for root in scannedRoots {
            for file in swiftFiles(under: root) {
                for line in try codeLines(file) where line.text.contains(/readOnly:\s*false/) {
                    hits.append("\(relative(file)):\(line.number)")
                }
            }
        }
        let foreign = hits.filter { hit in !writeClientFiles.contains { hit.hasPrefix($0 + ":") } }
        #expect(foreign.isEmpty, "write-capable client built outside \(writeClientFiles): \(foreign)")
    }

    @Test func auditExportAndDatabaseNeverContainTokens() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: Scenarios.twelveItems)
        await h.fake.inject(.timeoutAfterApply)
        await h.fake.inject(.conflict(code: "ENTITY_ERROR", detail: "Synthetic refusal"))
        _ = try await h.makeExecutor().apply(planId: planId, confirm: Confirm.accept)
        let requests = await h.fake.requests()
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.hadAuthorization })
        let export = FileManager.default.temporaryDirectory.appending(path: "purser-audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: export) }
        #expect(try h.audit.exportJSONL(to: export) > 0)
        let exported = try String(contentsOf: export, encoding: .utf8)
        #expect(exported.contains("httpSent"))
        #expect(!exported.contains("Bearer "))
        #expect(!exported.contains("eyJ"))
        let dump = try h.dumpDatabase()
        #expect(dump.contains("httpSent"))
        #expect(!dump.contains("Bearer "))
        #expect(!dump.contains("eyJ"))
    }

    @Test func readOnlyClientRefusesEveryWriteWithoutSendingIt() async throws {
        let clock = TestClock.at(ExecutorHarness.start)
        let fake = FakeASC(model: FakeSeed.fruitJar(), now: clock.nowFunction)
        let client = LiveASCClient(http: try await WriteTestClients.http(transport: fake, readOnly: true, products: ["sub-y", "iap-life"],
                                                                         children: ["x"], now: clock.nowFunction))
        let d = CalendarDate(iso: "2026-11-01")!
        let attempts: [@Sendable () async throws -> Void] = [
            { _ = try await client.createRegularPrice(NewRegularPrice(subscriptionId: "sub-y", territory: "USA", planType: .upfront,
                                                                      pricePointId: "pp-sub-y-USA-1", startDate: d, preserveCurrentPrice: true)) },
            { try await client.deleteRegularPrice(ascId: "x") },
            { _ = try await client.createIntroductoryOffer(NewIntroOffer(subscriptionId: "sub-y", territory: "USA", planType: .upfront,
                                                                         mode: .freeTrial, duration: .oneWeek, numberOfPeriods: 1,
                                                                         startDate: d, endDate: nil, pricePointId: nil)) },
            { try await client.endIntroductoryOffer(ascId: "x", endDate: d) },
            { try await client.deleteIntroductoryOffer(ascId: "x") },
            { _ = try await client.createPromotionalOffer(NewPromoOffer(subscriptionId: "sub-y", offerCode: "ro_v1", name: "ro", mode: .freeTrial,
                                                                        duration: .oneMonth, numberOfPeriods: 1, planType: .upfront,
                                                                        prices: [NewPromoPrice(territory: "USA", pricePointId: nil)])) },
            { try await client.replacePromotionalOfferPrices(ascId: "x", prices: []) },
            { try await client.deletePromotionalOffer(ascId: "x") },
            { try await client.replaceIAPPriceSchedule(NewIAPSchedule(iapId: "iap-life", baseTerritory: "USA", manualPrices: [])) },
        ]
        for attempt in attempts {
            await #expect(throws: ASCError.readOnlyClient) { try await attempt() }
        }
        #expect(await fake.requests().isEmpty)
    }

    @Test func executorWithAReadOnlyWriterFailsItemsAndWritesNothing() async throws {
        let h = try await ExecutorHarness.make()
        let (planId, _) = try await Scenarios.plan(h, cells: [Scenarios.newRegularPrice(sub: "sub-y", territory: "GBR", pointIndex: 14, start: "2026-11-15")])
        let readOnly = LiveASCClient(http: try await WriteTestClients.http(transport: h.fake, readOnly: true, products: ["sub-y"],
                                                                           budget: h.budget, appGuard: h.appGuard, now: h.clock.nowFunction))
        _ = try await h.makeExecutor(writer: readOnly).apply(planId: planId, confirm: Confirm.accept)
        #expect(try h.store.items(planId: planId).map(\.state) == [.failed])
        #expect(await h.fake.writeRequests().isEmpty)
    }
}
