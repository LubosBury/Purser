import Foundation
import Domain
import Store
import ASCClient

extension Executor {
    /// `createdVersions`: owner -> id of the version that a Done or Effective createMetadataVersion item of the plan created.
    static func createdVersions(in ledger: [Int: StoredItem]) -> [LocalizationOwner: String] {
        var result: [LocalizationOwner: String] = [:]
        for stored in ledger.values where stored.state == .done || stored.state == .effective {
            guard case let .createMetadataVersion(owner) = stored.item.payload, let ascId = stored.ascId, !ascId.isEmpty else { continue }
            result[owner] = ascId
        }
        return result
    }

    /// L3: after a lost answer or a 5xx to a version POST the item stays InFlight and only a read decides. Apple cannot
    /// delete a version and refuses a second one with 409, so a read that does not show the version yet never leads to a
    /// second POST: the item waits (NETWORK, `maxAutomaticWaits`, then the plan stays paused) and `process` reads again
    /// through `.retry`, after the loop checked pause and abort. An editable pending version -> Done with its id; a version
    /// in review or approved -> Stale. A failed read waits like any read (waitAfterFailedRead).
    func confirmVersionByRead(seq: Int, context: inout RunContext) async throws -> ItemStep {
        let planId = context.planId
        guard let stored = ledgers[planId]?[seq] else { return .next }
        let live: CellState
        do {
            context.view.apply(try await cellReader.read(stored.item.cell, in: context.view.snapshot))
            live = context.view.state(stored.item.cell, today: today)
        } catch let error as ASCError {
            try await waitAfterFailedRead(error, context: &context)
            return .retry
        }
        switch Reconciler.resolve(stored.item, live: live, today: today) {
        case let .targetFound(ascId):
            try setItem(planId, seq, to: .done, ascId: ascId, note: "fresh read found the version")
            context.view.set(stored.item.cell, Reconciler.fillCreated(stored.item.target, ascId: ascId))
            return .next
        case .unchanged:
            try await pauseAndWait(.network, cause: "a read does not show the version the POST may have created; it is not sent again",
                                   context: &context)
            return .retry
        case .diverged:
            try setItem(planId, seq, to: .stale, note: "fresh read: the owner's version is in review or approved")
            try skipDependents(of: seq, planId: planId, reason: "is stale")
            return .next
        }
    }

    /// L3: before a text without ids goes into a version this plan created, the owner is read again, once per run after the
    /// version exists. A read from before the version shows neither it nor the rows Apple copied into it, so the Reconciler
    /// would miss a carried-over text that is already there and `prepare` would not find the row to PATCH. The read becomes
    /// the run's cached read, which `prepare`'s `fresh` closure returns. A read that does not show
    /// the version yet is dropped (`versionNotVisible`); a failed read throws its ASCError. `process` waits after either
    /// and tries the item again, so nothing is sent before a read shows the version.
    func readCreatedVersionBeforeText(_ item: PlannedItem, context: inout RunContext) async throws {
        guard case let .setLocalization(s) = item.payload, s.localizationId == nil, s.versionId == nil,
              let version = createdVersions(context.planId)[s.owner] else { return }
        if context.freshMetadata[s.owner]?.versions.contains(where: { $0.ascId == version }) == true { return }
        let read = try await reader.metadata(owner: s.owner)
        try LocalizationResolver.requireVersion(version, in: read)
        context.view.apply(.metadata(read))
        context.freshMetadata[s.owner] = read
    }
}
