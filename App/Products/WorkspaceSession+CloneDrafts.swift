import Foundation
import Catalog
import Domain
import Executor
import Planner
import PurserSecurity

/// What a clone request finds in App Store Connect when the sheet is about to prepare drafts without cloning.
enum CloneState {
    /// Steps a run would write are still missing: they must be shown and confirmed like any clone.
    case missing(ClonePreview)
    /// Nothing is missing; source ASC id -> clone ASC id.
    case complete(created: [String: String])
}

/// Refuses every write: a clone run built with it can read, and stops where it would ask for Touch ID.
private struct RefusingGate: BiometricGate {
    func authenticate(reason: String) async throws { throw BiometricError.notAuthenticated }
}

extension WorkspaceSession {
    /// The price drafts of a clone (spec "Localizations and cloning" §6, "Draft plans"): a sync that brings the clones into
    /// the catalog, then one Draft per CloneDrafts spec, saved through the planning model like any other plan and titled
    /// with its place in the order of application. No draft is opened (the Clone sheet and MCP list them). Writes nothing
    /// to App Store Connect.
    ///
    /// It can be run again at any time with all the clones: a spec whose title a plan that has not ended already carries is
    /// reported ("Draft already exists", or "Plan already exists" once it is no longer a Draft) and not built, and a Draft
    /// that failed before is built now.
    ///
    /// The drafts phase is part of the clone run (ProductRuns): this refuses, before anything is read, while another
    /// creation or clone, or the drafts of one, is in progress.
    func prepareCloneDrafts(created: [String: String], copy: CloneCopy, offerCodeSuffix: String) async throws -> CloneDraftOutcome {
        let claim = try productRuns.claim(.clone)
        return await prepareCloneDrafts(created: created, copy: copy, offerCodeSuffix: offerCodeSuffix, holding: claim)
    }

    /// The same, for the caller of a clone that kept its claim (`ProductCreator.clone(_:snapshot:holding:)`): the run stays
    /// marked until the drafts are done, and the claim is released here, whatever the outcome.
    func prepareCloneDrafts(created: [String: String], copy: CloneCopy, offerCodeSuffix: String,
                            holding claim: ProductRunClaim) async -> CloneDraftOutcome {
        defer { claim.release() }
        guard !created.isEmpty else { return CloneDraftOutcome() }
        if let reason = syncBlockedReason { return CloneDraftOutcome(syncProblem: reason) }
        while isSyncing { try? await Task.sleep(for: .milliseconds(200)) }
        errorMessage = nil
        await syncNow()
        if let problem = errorMessage { return CloneDraftOutcome(syncProblem: problem) }
        guard let snapshot = planning.snapshot,
              created.values.allSatisfy({ snapshot.subscriptions[$0] != nil || snapshot.iaps[$0] != nil }) else {
            return CloneDraftOutcome(syncProblem: "The sync did not bring every clone into the catalog.")
        }
        let today = planning.today
        var outcome = CloneDraftOutcome(notes: CloneDrafts.notCopied(created: created, copy: copy, offerCodeSuffix: offerCodeSuffix,
                                                                     snapshot: snapshot, today: today))
        let specs = CloneDrafts.specs(created: created, copy: copy, offerCodeSuffix: offerCodeSuffix, snapshot: snapshot, today: today)
        // The sync reloaded the plans; every build below reloads them again.
        for action in CloneDrafts.actions(for: specs, open: CloneDrafts.openPlans(in: planning.plans)) {
            switch action {
            case let .exists(line):
                outcome.drafts.append(line)
            case let .build(title, spec):
                planning.errorMessage = nil
                // Not opened: opening a plan switches the window to Plans, which would close the Clone sheet.
                if let id = await planning.buildWithoutOpening(spec, reason: title) {
                    outcome.drafts.append(CloneDraftOutcome.Line(title: title, planId: id, error: nil))
                } else {
                    outcome.drafts.append(CloneDraftOutcome.Line(title: title, planId: nil,
                                                                 error: planning.errorMessage ?? "The draft could not be built."))
                    planning.errorMessage = nil
                }
            }
        }
        return outcome
    }

    /// Reads a clone request again and says whether steps a run would write are still missing. When none are (blocked steps
    /// aside: a run reports them without writing), a run that cannot write finds the clones that exist (its gate refuses
    /// Touch ID, so a change between the two reads stops it instead of writing).
    func cloneState(_ request: CloneRequest, snapshot: CatalogSnapshot) async throws -> CloneState {
        let preview = try await makeProductCreator().previewClone(request, snapshot: snapshot)
        guard preview.writable.isEmpty else { return .missing(preview) }
        do {
            return .complete(created: try await makeProductCreator(gate: RefusingGate()).clone(request, snapshot: snapshot).created)
        } catch is BiometricError {
            throw ProductCreationError.invalid(["App Store Connect changed while it was read; press Check again."])
        }
    }
}
