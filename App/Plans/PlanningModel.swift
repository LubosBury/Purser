import Foundation
import Observation
import Domain
import Store
import Audit
import Catalog
import Importer
import Policy
import Planner
import ASCClient

enum ImportTemplateFailure: Error, CustomStringConvertible {
    case noSnapshot, cannotSaveMapping, noPricedProducts

    var description: String {
        switch self {
        case .noSnapshot: return "The catalog is empty; run a sync first."
        case .cannotSaveMapping: return "The import mapping cannot be saved right now."
        case .noPricedProducts: return "No subscription has a price yet; set the first price on the Regular price tab."
        }
    }
}

struct ImportOutcome {
    var table: ImportedTable
    var verdicts: [Verdict]
    var hasBlock: Bool { verdicts.contains { if case .block = $0.severity { return true } else { return false } } }
}

struct PlanPresentation: Identifiable {
    var plan: StoredPlan
    var spec: PlanSpec
    var rows: [PlanDiffRow]
    /// nil while the import check is still being computed.
    var checkDiffs: [CheckDiff]?
    var opCounts: [(op: ItemOp, count: Int)]
    var nearestDate: CalendarDate?
    var snapshotTakenAt: Date?
    /// L3: names of the owners whose new version waits for submission in App Store Connect.
    var readyForReview: [String] = []
    /// L3: names of the owners whose new version exists but not all of whose texts were written.
    var incompleteVersions: [String] = []
    var id: String { plan.id }
}

/// A plan that is being opened: the Plan screen shows its header at once and a placeholder until the rows are ready.
struct PlanOpening {
    var id: String
    var plan: StoredPlan?
}

/// Planning for one workspace (M1): import, draft plans, findings. Nothing here can write to ASC.
/// Uses the session's planner, planStore and persistence (K11); database reads run off the main actor.
@MainActor
@Observable
final class PlanningModel {
    struct Dependencies: Sendable {
        var audit: AuditLog
        var catalog: CatalogStore
        var store: PlanStore
        var persistence: PlanPersistence
        var rateLimit: @Sendable () async -> RateLimitSnapshot?
    }

    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored let google: GoogleAccount
    /// WorkspaceSession.planner; replaced by update(config:planner:) after saveConfig(_:).
    @ObservationIgnored private var planner: Planner
    @ObservationIgnored private let acknowledger: FindingAcknowledger
    @ObservationIgnored let names: TerritoryNameMap

    /// The saved workspace config (import mapping, Google source, nominal discounts).
    private(set) var config: WorkspaceConfig
    private(set) var snapshot: CatalogSnapshot?
    private(set) var plans: [StoredPlan] = []
    private(set) var findings: [FindingRecord] = []
    var presentation: PlanPresentation?
    private(set) var opening: PlanOpening?
    /// Counts `open` and `closePlan` calls; an older open that finishes later is dropped.
    @ObservationIgnored private var openGeneration = 0
    var errorMessage: String?
    var isWorking = false

    init(deps: Dependencies, config: WorkspaceConfig, planner: Planner, google: GoogleAccount) throws {
        self.deps = deps
        self.config = config
        self.planner = planner
        self.google = google
        acknowledger = FindingAcknowledger(catalog: deps.catalog, audit: deps.audit, now: { Date() })
        names = try TerritoryNameMap.bundled()
    }

    /// WorkspaceSession.saveConfig(_:) hands over the saved config and the planner rebuilt for it, so a new import mapping,
    /// Google source or nominal discount (I5) applies without reopening the workspace.
    func update(config: WorkspaceConfig, planner: Planner) {
        self.config = config
        self.planner = planner
    }

    var today: CalendarDate { CalendarDate.today(now: Date()) }
    /// The plan on the Plan screen, loaded or still opening.
    var shownPlanId: String? { presentation?.id ?? opening?.id }
    var findingGroups: [FindingGroup] { FindingGroups.group(findings) }
    var subscriptions: [SubscriptionInfo] { (snapshot?.subscriptions.values).map { $0.sorted { $0.name < $1.name } } ?? [] }
    var iaps: [IAPInfo] { (snapshot?.iaps.values).map { $0.sorted { $0.name < $1.name } } ?? [] }
    var promoOffers: [PromoOffer] { snapshot?.promoOffers.sorted { ($0.subscriptionId, $0.offerCode) < ($1.subscriptionId, $1.offerCode) } ?? [] }

    /// The product's name; a subscription group's reference name (text findings); else the asc id.
    func productName(_ ascId: String) -> String {
        snapshot?.subscriptions[ascId]?.name ?? snapshot?.iaps[ascId]?.name ?? snapshot?.groups[ascId]?.referenceName ?? ascId
    }

    /// Reloads snapshot, plans and open findings off the main actor (the snapshot decodes every live observation and
    /// price point); WorkspaceSession calls it after every sync.
    func reload() async {
        let catalog = deps.catalog
        let store = deps.store
        do {
            let (snapshot, plans, findings) = try await Task.detached(priority: .userInitiated) {
                (try catalog.latestSnapshot(),
                 try store.plans(states: nil).sorted { $0.createdAt > $1.createdAt },
                 try catalog.findings(includeAcked: false))
            }.value
            self.snapshot = snapshot
            self.plans = plans
            self.findings = findings
        } catch {
            errorMessage = "Loading failed: \(error)"
        }
    }

    /// Plans only. Saving, re-planning or cancelling a draft does not touch the catalog, so the snapshot (the slow
    /// part of `reload()`) stays as it is.
    private func reloadPlans() async {
        let store = deps.store
        do {
            plans = try await Task.detached(priority: .userInitiated) {
                try store.plans(states: nil).sorted { $0.createdAt > $1.createdAt }
            }.value
        } catch {
            errorMessage = "Loading failed: \(error)"
        }
    }

    /// Open findings only; an ack changes nothing else.
    private func reloadFindings() async {
        let catalog = deps.catalog
        do {
            findings = try await Task.detached(priority: .userInitiated) { try catalog.findings(includeAcked: false) }.value
        } catch {
            errorMessage = "Loading failed: \(error)"
        }
    }

    // MARK: M4 tabs (Promo, IAP, Regular price)

    /// Reads Apple's equalizations of a subscription price point (subscription id, price point id, plan type).
    /// Set by WorkspaceSession while its read-only ASC client exists; nil when sync is unavailable.
    @ObservationIgnored var equalizer: (@Sendable (String, String, PlanType?) async throws -> [PricePoint])?

    /// Read-only access for OfferCodeRegistryReader (Promo tab): the workspace database of the session's PlanStore (K2).
    var database: WorkspaceDatabase { deps.store.database }

    /// The planner `build(_:reason:)` uses, so a tab's live preview equals the Draft it saves.
    var sharedPlanner: Planner { planner }

    // MARK: import

    func importCSV(from url: URL) async -> ImportOutcome? {
        guard let mapping = config.importMapping else { errorMessage = "The workspace has no import mapping."; return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try await runImport(CSVTableSource(data: try Data(contentsOf: url)), mapping: mapping)
        } catch {
            errorMessage = "The CSV cannot be loaded: \(error)"
            return nil
        }
    }

    /// The same import for a table that arrives as text (the MCP bridge; the sandbox keeps the app from the file).
    func importCSV(text: String) async -> ImportOutcome? {
        guard let mapping = config.importMapping else { errorMessage = "The workspace has no import mapping."; return nil }
        do {
            return try await runImport(CSVTableSource(data: Data(text.utf8)), mapping: mapping, emptyWrittenCells: .skip)
        } catch {
            errorMessage = "The CSV cannot be loaded: \(error)"
            return nil
        }
    }

    func importGoogleSheet() async -> ImportOutcome? {
        guard let mapping = config.importMapping, case let .googleSheet(spreadsheetId, range) = mapping.source else {
            errorMessage = "The import mapping has no Google Sheet source."
            return nil
        }
        guard let clientId = config.googleClientId else { errorMessage = "The Google client id is missing."; return nil }
        let provider = google.tokenProvider(clientId: clientId)
        let source = GoogleSheetsTableSource(spreadsheetId: spreadsheetId, range: range, transport: google.transport,
                                             accessToken: { try await provider.accessToken() })
        do {
            return try await runImport(source, mapping: mapping)
        } catch {
            errorMessage = "The sheet cannot be loaded: \(error)"
            return nil
        }
    }

    // MARK: import template

    /// Saves a new import mapping into the workspace config (with its audit event). Set by WorkspaceSession.
    @ObservationIgnored var saveImportMapping: (@MainActor (ImportMapping) throws -> Void)?

    struct ImportTemplateExport {
        var productCount: Int
        var territoryCount: Int
        var mappingVersion: Int
        var withoutPrice: [String]            // product ids left out because they have no price yet
        var skippedTerritories: [TerritoryCode]
    }

    /// Writes the predefined import table (country, currency, one regular-price column per subscription that has a
    /// price, filled with today's prices) to `url` and makes its layout the workspace's import mapping.
    func exportImportTemplate(to url: URL) throws -> ImportTemplateExport {
        guard let snapshot else { throw ImportTemplateFailure.noSnapshot }
        guard let saveImportMapping else { throw ImportTemplateFailure.cannotSaveMapping }
        let today = self.today
        var prices: [String: [TerritoryCode: Decimal]] = [:]
        var products: [ImportTemplate.Product] = []
        var withoutPrice: [String] = []
        for subscription in snapshot.subscriptions.values.sorted(by: { $0.productId < $1.productId }) {
            var row: [TerritoryCode: Decimal] = [:]
            for territory in subscription.availableTerritories {
                if case let .regular(current, _) = snapshot.cellState(.regular(subscriptionId: subscription.ascId, territory: territory, planType: .upfront), on: today),
                   let current {
                    row[territory] = current.customerPrice
                }
            }
            if row.isEmpty {
                withoutPrice.append(subscription.productId)
            } else {
                prices[subscription.ascId] = row
                products.append(ImportTemplate.Product(ascId: subscription.ascId, productId: subscription.productId))
            }
        }
        guard !products.isEmpty else { throw ImportTemplateFailure.noPricedProducts }
        let template = try ImportTemplate.csv(products: products, territories: snapshot.territories, prices: prices)
        try Data(template.text.utf8).write(to: url, options: .atomic)
        var version = config.importMapping?.version ?? 0
        if config.importMapping != ImportTemplate.mapping(products: products, version: version) {
            version += 1
            try saveImportMapping(ImportTemplate.mapping(products: products, version: version))
        }
        return ImportTemplateExport(productCount: products.count, territoryCount: snapshot.territories.count - template.skipped.count,
                                    mappingVersion: version, withoutPrice: withoutPrice, skippedTerritories: template.skipped)
    }

    private func runImport(_ source: any TableSource, mapping: ImportMapping,
                           emptyWrittenCells: EmptyWrittenCells = .refuse) async throws -> ImportOutcome {
        let importer = Importer(names: names)
        let (table, verdicts) = try await importer.importTable(source: source, mapping: mapping, territories: snapshot?.territories ?? [:],
                                                               emptyWrittenCells: emptyWrittenCells)
        return ImportOutcome(table: table, verdicts: verdicts)
    }

    // MARK: plans

    /// Plans `spec` against the latest snapshot, stores it as a Draft and opens it.
    func build(_ spec: PlanSpec, reason: String?) async -> Bool {
        guard let saved = await planAndStore(spec, reason: reason) else { return false }
        await open(planId: saved.id, draft: saved.draft)
        return true
    }

    /// Plans `spec` and stores it as a Draft without opening it, so the window stays on its screen: a clone's drafts are
    /// built while the Clone sheet is shown, and opening one would switch to Plans and close the sheet. Returns the
    /// Draft's id, or nil with `errorMessage` set.
    func buildWithoutOpening(_ spec: PlanSpec, reason: String?) async -> String? {
        await planAndStore(spec, reason: reason)?.id
    }

    private func planAndStore(_ spec: PlanSpec, reason: String?) async -> (id: String, draft: PlanDraft)? {
        guard let draft = await draft(spec) else { return nil }
        do {
            let id = try deps.persistence.saveDraft(draft, binding: PlanBinding(config: config), reason: reason, replanOf: nil)
            await reloadPlans()
            return (id, draft)
        } catch {
            errorMessage = "The plan cannot be saved: \(error)"
            return nil
        }
    }

    func replan(planId: String) async {
        guard let stored = plans.first(where: { $0.id == planId }),
              let spec = try? JSONCoding.decode(PlanSpec.self, from: stored.specJSON),
              let draft = await draft(spec) else { return }
        do {
            let id = try deps.persistence.replan(planId: planId, with: draft, binding: PlanBinding(config: config), reason: nil)
            await reloadPlans()
            await open(planId: id, draft: draft)
        } catch {
            errorMessage = "Re-plan failed: \(error)"
        }
    }

    func cancel(planId: String) async {
        do {
            try deps.persistence.cancel(planId: planId)
            await reloadPlans()
            if presentation?.plan.id == planId, let plan = plans.first(where: { $0.id == planId }) { presentation?.plan = plan }
        } catch {
            errorMessage = "The plan cannot be cancelled: \(error)"
        }
    }

    /// Opens the Plan screen at once (`opening`) and fills it when the plan is read and its rows are built, off the
    /// main actor. The import check of a stored import plan needs a re-plan and arrives after the rows.
    func open(planId: String, draft: PlanDraft? = nil) async {
        guard let snapshot else { return }
        PlanOpenTrace.begin(planId)
        openGeneration += 1
        let generation = openGeneration
        // A freshly built draft (build, re-plan) is ready at once and replaces the screen in place; a stored plan
        // shows the placeholder, also when another plan is still on the screen.
        if presentation == nil || (draft == nil && presentation?.id != planId) {
            presentation = nil
            opening = PlanOpening(id: planId, plan: plans.first { $0.id == planId })
        }
        defer { if generation == openGeneration { opening = nil } }
        let store = deps.store
        let config = self.config
        let today = self.today
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try Self.load(planId: planId, checkDiffs: draft?.checkDiffs, store: store, snapshot: snapshot, config: config, today: today)
            }.value
            guard generation == openGeneration, let loaded else { return }
            presentation = loaded
            opening = nil
            PlanOpenTrace.mark("presentation set")
            guard loaded.checkDiffs == nil else { return }
            let checkDiffs = await self.draft(loaded.spec)?.checkDiffs ?? []
            guard generation == openGeneration, presentation?.id == planId else { return }
            presentation?.checkDiffs = checkDiffs
            PlanOpenTrace.mark("import check ready")
        } catch {
            guard generation == openGeneration else { return }
            errorMessage = "The plan cannot be opened: \(error)"
        }
    }

    /// Leaves the Plan screen; an open that is still running is dropped.
    func closePlan() {
        openGeneration += 1
        opening = nil
        presentation = nil
    }

    /// Reads the plan and builds what the Plan screen shows. `checkDiffs` stays nil only for an import plan opened
    /// without its draft.
    private nonisolated static func load(planId: String, checkDiffs: [CheckDiff]?, store: PlanStore, snapshot: CatalogSnapshot,
                                         config: WorkspaceConfig, today: CalendarDate) throws -> PlanPresentation? {
        guard let plan = try store.plan(id: planId) else { return nil }
        let spec = try JSONCoding.decode(PlanSpec.self, from: plan.specJSON)
        let stored = try store.items(planId: planId)
        let items = stored.map(\.item)
        PlanOpenTrace.mark("plan and \(items.count) items read")
        var isImport = false
        if case .importTable = spec.unwrapped { isImport = true }
        let checkDiffs = checkDiffs ?? (isImport ? nil : [])
        let rows = PlanDiff.rows(items: items, verdicts: plan.verdicts, spec: spec, snapshot: snapshot, config: config, today: today)
        PlanOpenTrace.mark("diff rows built")
        let counts = Dictionary(grouping: items, by: \.op).map { (op: $0.key, count: $0.value.count) }.sorted { $0.op.rawValue < $1.op.rawValue }
        let dates = items.compactMap { item -> CalendarDate? in
            switch item.payload {
            case let .createRegularPrice(p): return p.startDate
            case let .createIntro(o): return o.startDate
            case let .endIntro(_, end): return end
            default: return nil
            }
        }
        let versions = ReadyForReview.status(plan: plan, items: stored, metadata: snapshot.metadata)
        return PlanPresentation(plan: plan, spec: spec, rows: rows, checkDiffs: checkDiffs, opCounts: counts,
                                nearestDate: dates.min(), snapshotTakenAt: snapshot.takenAt,
                                readyForReview: versions.ready.map { snapshot.ownerName($0) },
                                incompleteVersions: versions.incomplete.map { snapshot.ownerName($0) })
    }

    /// Builds a draft off the main actor. The context carries the rate limit (A7, estimate), the stored items of a
    /// withdrawn plan (WITHDRAW) and the products unlocked by an Effective canary (I7, CR-11).
    private func draft(_ spec: PlanSpec) async -> PlanDraft? {
        guard let snapshot else { errorMessage = "The catalog is empty; press Sync first."; return nil }
        isWorking = true
        defer { isWorking = false }
        let rateLimit = await deps.rateLimit()
        let config = self.config
        let today = self.today
        let planner = self.planner
        let store = deps.store
        do {
            return try await Task.detached(priority: .userInitiated) {
                var referenced: [String: [StoredItem]] = [:]
                if case let .withdraw(withdraw) = spec.unwrapped { referenced[withdraw.planId] = try store.items(planId: withdraw.planId) }
                let context = PlanningContext(snapshot: snapshot, config: config, today: today, rateLimit: rateLimit,
                                              referencedItems: referenced,
                                              effectiveLiveIntroCanaryProducts: try LiveIntroCanaries.unlockedProducts(store: store))
                return try planner.plan(spec, context: context)
            }.value
        } catch {
            errorMessage = "The plan cannot be built: \(error)"
            return nil
        }
    }

    // MARK: findings

    func fixPrefill(for group: FindingGroup) -> FixPrefill? {
        guard let snapshot else { return nil }
        return FixPrefill.forGroup(group, snapshot: snapshot, config: config, today: today)
    }

    func ack(_ group: FindingGroup, reason: String) async -> Bool {
        do {
            try acknowledger.ack(findingIds: group.findingIds, reason: reason)
            await reloadFindings()
            return true
        } catch FindingAckError.reasonTooShort(let minimum) {
            errorMessage = "The reason must have at least \(minimum) characters."
            return false
        } catch {
            errorMessage = "Acknowledging failed: \(error)"
            return false
        }
    }
}
