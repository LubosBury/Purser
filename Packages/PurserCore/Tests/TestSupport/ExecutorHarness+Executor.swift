import Foundation
import Domain
import PurserSecurity
import ASCClient
import Catalog
import Policy
import Executor

extension ExecutorHarness {
    /// `reader` replaces the Executor's own reads (preflight app check, cell and owner reads). Its syncs (preflight, verify)
    /// keep the harness reader unless `syncReader` is given.
    public func makeExecutor(policy: PolicyEngine = PolicyEngine(planRules: [], invariants: []),
                             gate: any BiometricGate = AlwaysAllowGate(), writer: (any ASCWriting)? = nil,
                             reader: (any ASCReading)? = nil, syncReader: (any ASCReading)? = nil) -> Executor {
        let engine = syncReader.map { SyncEngine(database: database, reader: $0, audit: audit, config: config, now: clock.nowFunction) } ?? sync
        return Executor(database: database, config: config, reader: reader ?? self.reader, writer: writer ?? self.writer, sync: engine,
                        catalog: catalog, policy: policy, audit: audit, gate: gate, budget: budget, now: clock.nowFunction,
                        sleep: clock.sleepFunction)
    }
}

public enum Confirm {
    public static let accept: @Sendable (ConfirmationRequest) async -> ConfirmationResponse = { request in
        ConfirmationResponse(accepted: true, acknowledgedExclusions: true, typedAppName: request.appName,
                             reason: "Synthetic test run approved by the owner", checkedRiskClasses: Set(request.riskClasses.keys))
    }

    public static let decline: @Sendable (ConfirmationRequest) async -> ConfirmationResponse = { _ in
        ConfirmationResponse(accepted: false, acknowledgedExclusions: false, typedAppName: nil, reason: nil, checkedRiskClasses: [])
    }

    public static func responding(_ response: ConfirmationResponse) -> @Sendable (ConfirmationRequest) async -> ConfirmationResponse {
        { _ in response }
    }
}
