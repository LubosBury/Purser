import Foundation
import ASCClient
import Executor
import PurserSecurity

extension ExecutorHarness {
    /// A ProductCreator over FakeASC: a write-capable client that shares this harness's AppGuard and budget, its read-only
    /// reader (or `reader`) and, unless `copiesImages` is false, an AssetTransfer over the same FakeASC (its upload and image hosts).
    /// Creators that share `runs` run one at a time (the app gives every creator its session's instance).
    public func makeProductCreator(gate: any BiometricGate = AlwaysAllowGate(), copiesImages: Bool = true,
                                   reader: (any ASCReading)? = nil, runs: ProductRuns = ProductRuns()) async throws -> ProductCreator {
        let http = try await WriteTestClients.http(transport: fake, readOnly: false, products: [], budget: budget, appGuard: appGuard,
                                                   now: clock.nowFunction)
        return ProductCreator(config: config, http: http, reader: reader ?? self.reader, audit: audit, budget: budget, gate: gate,
                              runs: runs, assets: copiesImages ? AssetTransfer(transport: fake, audit: audit) : nil)
    }
}
