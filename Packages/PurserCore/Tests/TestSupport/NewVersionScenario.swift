import Foundation
import Domain
import Store
import Catalog
import Policy
import Planner

/// L3: a localization plan on sub-y (APPROVED, ver-sub-y-1 with en-US and cs in FakeSeed) that renames en-US and adds
/// de-DE, so the Planner opens a new version. Synthetic data only.
public enum NewVersionScenario {
    public static let owner = LocalizationOwner.subscription("sub-y")
    public static let newName = "Yearly Plus"
    public static let german = LocalizationText(name: "Jahresabo", description: "Ein Jahr Premium")

    public enum ScenarioError: Error { case noLiveVersion }

    public struct Planned: Sendable {
        public var planId: String
        public var draft: PlanDraft
        public var live: MetadataVersion
        /// locale -> text of the Live version when the plan was built
        public var liveTexts: [String: LocalizationText]
    }

    public static func plan(_ h: ExecutorHarness) async throws -> Planned {
        let snapshot = try await h.initialSync()
        guard let live = snapshot.liveVersion(of: owner) else { throw ScenarioError.noLiveVersion }
        var liveTexts: [String: LocalizationText] = [:]
        for row in snapshot.metadata[owner]?.localizations ?? [] where row.versionId == live.ascId { liveTexts[row.locale] = row.text }
        let spec = PlanSpec.localization(LocalizationPlanSpec(edits: [
            LocalizationEdit(owner: owner, locale: "en-US", name: newName),
            LocalizationEdit(owner: owner, locale: "de-DE", name: german.name, description: german.description),
        ]))
        let draft = try Planner(policy: PolicyEngine()).plan(spec, context: PlanningContext(snapshot: snapshot, config: h.config, today: h.today))
        let planId = try PlanPersistence(store: h.store, audit: h.audit, appBuild: "test")
            .saveDraft(draft, binding: PlanBinding(config: h.config), reason: nil, replanOf: nil)
        return Planned(planId: planId, draft: draft, live: live, liveTexts: liveTexts)
    }

    public static func versionSeq(_ planned: Planned) -> Int? {
        planned.draft.items.first { if case .createMetadataVersion = $0.payload { return true } else { return false } }?.seq
    }

    public static func seq(_ planned: Planned, locale: String) -> Int? {
        planned.draft.items.first { if case let .setLocalization(s) = $0.payload { return s.locale == locale } else { return false } }?.seq
    }
}
