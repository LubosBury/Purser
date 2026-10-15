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
private let writeCallPattern = #"(?:try\s+)?await\s+[\w.?!\[\]()]*\.(createRegularPrice|deleteRegularPrice|createIntroductoryOffer|endIntroductoryOffer|deleteIntroductoryOffer|createPromotionalOffer|replacePromotionalOfferPrices|deletePromotionalOffer|replaceIAPPriceSchedule|createMetadataVersion|createLocalization|updateLocalization)\("#

/// The only files that may build a write-capable ASCHTTPClient (K11). WorkspaceSession+ApprovedProbe.swift does not exist
/// yet: the README reserves it for the DEBUG ApprovedProbe, which comes only after OQ1 is approved in writing.
private let writeClientFiles = ["App/Session/WorkspaceSession+Apply.swift", "App/Session/WorkspaceSession+SpikeProbe.swift",
                                "App/Session/WorkspaceSession+ApprovedProbe.swift"]

/// Every type that conforms to BiometricGate ("<file>: <type>"). Touch ID itself and the test gate live in Sources/Security;
/// the MCP gate stands in for Touch ID on an allowed MCP write, the clone drafts' gate refuses every write. A new gate,
/// above all one that lets a write through without asking, has to be added here on purpose.
private let biometricGates: Set<String> = [
    "Packages/PurserCore/Sources/Security/BiometricGate.swift: LocalAuthenticationGate",
    "Packages/PurserCore/Sources/Security/BiometricGate.swift: AlwaysAllowGate",
    "App/MCP/MCPBridgeHost.swift: MCPWriteGate",
    "App/Products/WorkspaceSession+CloneDrafts.swift: RefusingGate",
]

private let scannedRoots = [packageRoot.appending(path: "Sources"), repoRoot.appending(path: "App"), repoRoot.appending(path: "LoginItem"),
                            repoRoot.appending(path: "MCPHelper")]

/// The only file that may build the gate that stands in for Touch ID on writes asked for over MCP.
private let mcpGateFile = "App/MCP/MCPToolRouter.swift"

/// The only file that talks to Apple's upload and image hosts (spec "Localizations and cloning" §3, AssetTransfer).
private let assetTransferFile = "Packages/PurserCore/Sources/Executor/AssetTransfer.swift"

/// The only files that may call `AssetTransfer.live(`, the way the app gets an AssetTransfer: its transport refuses redirects.
/// Nothing but `live` itself builds an AssetTransfer with `AssetTransfer(` or `AssetTransfer.init(`. Tests are not scanned.
private let assetTransferLiveCallers = ["App/Session/WorkspaceSession+Apply.swift"]

/// The only file that names the type URLSession: every network session of the app is made there.
private let urlSessionFile = "Packages/PurserCore/Sources/ASCClient/HTTPTransport.swift"

/// The files that build an HTTP request themselves; every other request goes through ASCHTTPClient or AssetTransfer.
private let requestBuilderFiles = [
    "Packages/PurserCore/Sources/ASCClient/ASCHTTPClient.swift", assetTransferFile,
    "Packages/PurserCore/Sources/Importer/GoogleOAuth.swift", "Packages/PurserCore/Sources/Importer/GoogleSheetsTableSource.swift",
    "Packages/PurserCore/Sources/Executor/SlackChainHeadPublisher.swift", "Packages/PurserCore/Sources/Executor/SlackNotifier.swift",
]

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

/// The names of the types declared in `code` that conform to BiometricGate. The scan covers the whole text, not a line at a
/// time: `[^{]` also matches a newline, so a conformance split over lines is found as long as it comes before the `{` of
/// the declaration.
private func biometricGateConformers(in code: String) throws -> [String] {
    let conformance = try NSRegularExpression(pattern: #"\b(?:struct|class|actor|enum|extension)\s+(\w+)\b[^{]*:[^{]*\bBiometricGate\b"#)
    return conformance.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
        Range(match.range(at: 1), in: code).map { String(code[$0]) }
    }
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

    @Test func localizedMetadataIsOnlyRead() throws {
        let lines = try codeLines(packageRoot.appending(path: "Sources/ASCClient/LiveASCClient+Metadata.swift"))
        #expect(!lines.isEmpty)
        let writes = lines.filter { $0.text.contains(".send(") || $0.text.contains(".delete(") || $0.text.contains(".sendRaw(") }
        #expect(writes.isEmpty, "LiveASCClient+Metadata.swift may only read: lines \(writes.map(\.number))")
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

    @Test func theGateThatSkipsTouchIDIsBuiltOnlyByTheMCPRouter() throws {
        var hits: [String] = []
        for root in scannedRoots {
            for file in swiftFiles(under: root) {
                for line in try codeLines(file) where line.text.contains("MCPWriteGate()") || line.text.contains("AlwaysAllowGate()") {
                    hits.append("\(relative(file)):\(line.number)")
                }
            }
        }
        #expect(!hits.isEmpty, "the MCP router no longer builds its gate; update this test")
        let foreign = hits.filter { !$0.hasPrefix(mcpGateFile + ":") }
        #expect(foreign.isEmpty, "a gate that skips Touch ID is built outside \(mcpGateFile): \(foreign)")
    }

    @Test func onlyTheKnownGatesStandInForTouchID() throws {
        var found: Set<String> = []
        for root in scannedRoots {
            for file in swiftFiles(under: root) {
                let code = try codeLines(file).map(\.text).joined(separator: "\n")
                for name in try biometricGateConformers(in: code) { found.insert("\(relative(file)): \(name)") }
            }
        }
        #expect(found == biometricGates, "BiometricGate conformers changed: \(found.symmetricDifference(biometricGates).sorted())")
    }

    /// A conformance split over lines is found as well as one on a single line.
    @Test func aGateConformanceSplitOverLinesIsFound() throws {
        let code = """
        struct OneLine: Sendable, BiometricGate {}
        struct Split: Sendable,
            BiometricGate {
        }
        final class ColonOnTheNextLine
            : Sendable
            , BiometricGate {
        }
        extension Late
        : BiometricGate {
        }
        struct Holds: Sendable {
            let gate: any BiometricGate
        }
        struct Plain {}
        func use(_ gate: any BiometricGate) {}
        """
        #expect(try biometricGateConformers(in: code) == ["OneLine", "Split", "ColonOnTheNextLine", "Late"])
    }

    @Test func theMCPRouterAuditsAndChecksTheSettingBeforeItRunsAWrite() throws {
        let source = try String(contentsOf: repoRoot.appending(path: mcpGateFile), encoding: .utf8)
        let setting = try #require(source.range(of: "definition.access == .ascWrite, !host.writesWithoutTouchID"))
        let audit = try #require(source.range(of: "session.audit.append(.mcpToolCalled"))
        let run = try #require(source.range(of: "try await run(name, request.arguments, session)"))
        #expect(setting.lowerBound < audit.lowerBound)
        #expect(audit.lowerBound < run.lowerBound)
    }

    @Test func assetTransferLivesInTheExecutorAndTheAppGetsItOnlyThroughLive() throws {
        let declaration = try codeLines(repoRoot.appending(path: assetTransferFile)).map(\.text).joined(separator: "\n")
        #expect(declaration.contains(/\bpublic\s+struct\s+AssetTransfer\b/))
        // The whole body of `live`: the transport that refuses redirects, nothing else.
        #expect(declaration.contains(/public\s+static\s+func\s+live\s*\(\s*audit\s*:\s*AuditLog\s*\)\s*->\s*AssetTransfer\s*\{\s*AssetTransfer\s*\(\s*transport\s*:\s*RedirectRefusingTransport\s*\(\s*\)\s*,\s*audit\s*:\s*audit\s*\)\s*\}/),
                "live no longer builds its AssetTransfer with the transport that refuses redirects alone")
        // The memberwise init is for tests only: outside the package (the app) the compiler allows nothing but `live`.
        #expect(declaration.contains(/\bpackage\s+init\s*\(\s*transport\s*:/), "AssetTransfer.init(transport:audit:) is no longer package")
        #expect(!declaration.contains(/\b(?:public|open)\s+init\s*\(\s*transport\s*:/), "AssetTransfer.init(transport:audit:) must not be public")
        // Not `\b`: Swift Regex uses Unicode word boundaries, and `Executor.AssetTransfer(` has none before the type name.
        let construction = /(?:^|[^A-Za-z0-9_])AssetTransfer\s*(?:\.init\s*)?\(/
        var built: [String] = []
        var live: [String] = []
        for root in scannedRoots {
            for file in swiftFiles(under: root) {
                for line in try codeLines(file) {
                    if relative(file) != assetTransferFile, line.text.contains(construction) { built.append("\(relative(file)):\(line.number)") }
                    if line.text.contains(/(?:^|[^A-Za-z0-9_])AssetTransfer\s*\.live\s*\(/) { live.append("\(relative(file)):\(line.number)") }
                }
            }
        }
        #expect(built.isEmpty, "AssetTransfer built outside AssetTransfer.live: \(built)")
        #expect(!live.isEmpty, "WorkspaceSession.makeProductCreator no longer obtains an AssetTransfer through AssetTransfer.live; update this test")
        let foreign = live.filter { hit in !assetTransferLiveCallers.contains { hit.hasPrefix($0 + ":") } }
        #expect(foreign.isEmpty, "AssetTransfer.live called outside \(assetTransferLiveCallers): \(foreign)")
    }

    /// Only the client that sent a screenshot reservation tells AppGuard which screenshots are its own: the hook is internal
    /// to ASCClient (no other module can name the source's screenshot as a reservation) and ASCHTTPClient is its one caller.
    @Test func onlyTheHTTPClientTellsAppGuardWhichScreenshotsAreItsOwn() throws {
        let appGuardFile = "Packages/PurserCore/Sources/ASCClient/AppGuard.swift"
        let clientFile = "Packages/PurserCore/Sources/ASCClient/ASCHTTPClient.swift"
        let lines = try codeLines(repoRoot.appending(path: appGuardFile))
        let hooks = lines.filter { $0.text.contains(/\bfunc\s+learnAnswer\b/) }
        #expect(hooks.count == 1, "AppGuard.learnAnswer is gone or declared twice; update this test")
        #expect(hooks.allSatisfy { !$0.text.contains(/\b(?:public|package|open)\b/) }, "AppGuard.learnAnswer must stay internal")
        #expect(lines.contains { $0.text.contains(/\bprivate\s+var\s+reservedScreenshots\b/) }, "AppGuard.reservedScreenshots must stay private")
        var callers: [String] = []
        for root in scannedRoots {
            for file in swiftFiles(under: root) where relative(file) != appGuardFile {
                for line in try codeLines(file) where line.text.contains(/(?:^|[^A-Za-z0-9_])learnAnswer\s*\(/) {
                    callers.append("\(relative(file)):\(line.number)")
                }
            }
        }
        #expect(!callers.isEmpty, "ASCHTTPClient no longer calls AppGuard.learnAnswer; update this test")
        let foreign = callers.filter { !$0.hasPrefix(clientFile + ":") }
        #expect(foreign.isEmpty, "AppGuard.learnAnswer called outside \(clientFile): \(foreign)")
    }

    @Test func assetTransferDoesNotKnowTheASCClientOrTheKey() throws {
        let source = try String(contentsOf: repoRoot.appending(path: assetTransferFile), encoding: .utf8)
        for forbidden in ["ASCHTTPClient", "JWTSigner", "PurserSecurity"] {
            #expect(!source.contains(forbidden), "\(assetTransferFile) mentions \(forbidden)")
        }
    }

    @Test func theTypeURLSessionIsNamedOnlyInTheTransportFile() throws {
        var foreign: [String] = []
        var inTransportFile = false
        for root in scannedRoots {
            for file in swiftFiles(under: root) {
                for line in try codeLines(file) where line.text.replacingOccurrences(of: "URLSessionTransport", with: "").contains("URLSession") {
                    if relative(file) == urlSessionFile { inTransportFile = true } else { foreign.append("\(relative(file)):\(line.number)") }
                }
            }
        }
        #expect(inTransportFile, "\(urlSessionFile) no longer names URLSession; update this test")
        #expect(foreign.isEmpty, "URLSession named outside \(urlSessionFile): \(foreign)")
    }

    @Test func onlyKnownFilesBuildHTTPRequests() throws {
        var foreign: [String] = []
        for root in scannedRoots {
            for file in swiftFiles(under: root) where !requestBuilderFiles.contains(relative(file)) {
                for line in try codeLines(file) where line.text.contains("URLRequest(") {
                    foreign.append("\(relative(file)):\(line.number)")
                }
            }
        }
        #expect(foreign.isEmpty, "HTTP requests built outside \(requestBuilderFiles): \(foreign)")
    }

    @Test func onlyAssetTransferKnowsTheUploadAndImageHosts() throws {
        var foreign: [String] = []
        for root in scannedRoots {
            for file in swiftFiles(under: root) where relative(file) != assetTransferFile {
                for line in try codeLines(file) where line.text.contains("mzstatic") || line.text.contains("\"uploadOperations\"") {
                    foreign.append("\(relative(file)):\(line.number)")
                }
            }
        }
        #expect(foreign.isEmpty, "the upload or image host is handled outside \(assetTransferFile): \(foreign)")
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
            { _ = try await client.createLocalization(versionId: "x", owner: .subscription("sub-y"), locale: "cs", text: LocalizationText(name: "Ovoce")) },
            { try await client.updateLocalization(localizationId: "x", owner: .subscription("sub-y"), text: LocalizationText(name: "Ovoce")) },
            { _ = try await client.createMetadataVersion(owner: .subscription("sub-y")) },
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

    /// L3: the write-call scan (writeCallPattern) must see createMetadataVersion, the ASCWriting method that creates a version.
    @Test func writeCallPatternCoversNewVersions() throws {
        let writeCall = try NSRegularExpression(pattern: writeCallPattern)
        let line = "        let version = try await writer.createMetadataVersion(owner: owner)"
        #expect(writeCall.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil)
    }
}
