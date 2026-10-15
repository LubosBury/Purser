import Foundation
import Observation
import Domain
import Catalog
import Importer
import Planner

/// The Localizations tab of NewPlanSheet: texts edited in Purser or read from a table, planned live, saved as an L10N Draft.
@MainActor @Observable
final class LocalizationPlanModel {
    enum Source: String, CaseIterable, Identifiable {
        case editor = "Edit in Purser", table = "Table"
        var id: String { rawValue }
    }

    enum Version: String {
        case draft = "Draft", inReview = "In review", live = "Live", new = "New"
    }

    /// One locale of the selected owner as the editor shows it; an empty field keeps the current text.
    struct Row: Identifiable, Hashable {
        var locale: String
        var name: String
        var description: String
        var customAppName: String
        var version: Version
        var id: String { locale }
    }

    let snapshot: CatalogSnapshot
    let config: WorkspaceConfig
    let today: CalendarDate
    @ObservationIgnored private let planning: PlanningModel
    @ObservationIgnored private let planner: Planner

    var source: Source = .editor
    private(set) var owner: LocalizationOwner?
    var rows: [Row] = []
    var newLocale = ""
    var sheetId = ""
    var sheetRange = "Localizations!A1:E1000"
    var reason = ""
    private(set) var tableEdits: [LocalizationEdit] = []
    private(set) var tableProblems: [String] = []
    private(set) var tableStatus: String?
    private(set) var draft: PlanDraft?
    private(set) var lastSpec: PlanSpec?
    private(set) var buildError: String?
    /// The `inputsFingerprint` the current draft was built from; the draft is stale while it differs.
    private(set) var builtFingerprint: String?

    init(planning: PlanningModel, snapshot: CatalogSnapshot, owner: LocalizationOwner?) {
        self.planning = planning
        self.snapshot = snapshot
        self.config = planning.config
        self.today = planning.today
        self.planner = planning.sharedPlanner
        select(owner)
    }

    /// nil while the workspace has no snapshot yet.
    static func make(planning: PlanningModel, owner: LocalizationOwner?) -> LocalizationPlanModel? {
        guard let snapshot = planning.snapshot else { return nil }
        return LocalizationPlanModel(planning: planning, snapshot: snapshot, owner: owner)
    }

    var owners: [LocalizationOwner] { snapshot.owners() }
    var isGroup: Bool { owner?.kind == .group }
    var hasPendingVersion: Bool { owner.flatMap { snapshot.pendingVersion(of: $0) } != nil }
    var canLoadSheet: Bool { planning.google.isSignedIn && !sheetId.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Apple's locales the owner does not have yet.
    var addableLocales: [String] { AppleConstants.localizationLocales.subtracting(rows.map(\.locale)).sorted() }

    func label(_ owner: LocalizationOwner) -> String {
        let kind: String
        switch owner.kind {
        case .subscription: kind = "Subscription"
        case .iap: kind = "One-time purchase"
        case .group: kind = "Subscription group"
        }
        return "\(kind) · \(snapshot.ownerName(owner))"
    }

    func select(_ owner: LocalizationOwner?) {
        self.owner = owner
        rows = owner.map(editorRows) ?? []
        newLocale = addableLocales.first ?? ""
    }

    private func editorRows(_ owner: LocalizationOwner) -> [Row] {
        let role = snapshot.pendingVersion(of: owner)?.state.role
        let version: Version = role == .editable ? .draft : (role == .inReview ? .inReview : .live)
        return snapshot.locales(of: owner).compactMap { locale in
            guard let text = LocalizationSemantics.effectiveText(snapshot.cellState(.localization(owner: owner, locale: locale), on: today)) else {
                return nil
            }
            return Row(locale: locale, name: text.name, description: text.description ?? "", customAppName: text.customAppName ?? "", version: version)
        }
    }

    func addLocale() {
        guard !newLocale.isEmpty, !rows.contains(where: { $0.locale == newLocale }) else { return }
        rows.append(Row(locale: newLocale, name: "", description: "", customAppName: "", version: .new))
        rows.sort { $0.locale < $1.locale }
        newLocale = addableLocales.first ?? ""
    }

    // MARK: Table

    func loadCSV(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try read(try await CSVTableSource(data: try Data(contentsOf: url)).fetchRows(), from: url.lastPathComponent)
        } catch {
            clearTable("The CSV cannot be loaded: \(error)")
        }
    }

    func loadSheet() async {
        guard let clientId = config.googleClientId else { clearTable("The Google client id is missing in the workspace settings."); return }
        let provider = planning.google.tokenProvider(clientId: clientId)
        let source = GoogleSheetsTableSource(spreadsheetId: sheetId.trimmingCharacters(in: .whitespaces), range: sheetRange,
                                             transport: planning.google.transport, accessToken: { try await provider.accessToken() })
        do {
            try read(try await source.fetchRows(), from: "the Google Sheet")
        } catch {
            clearTable("The sheet cannot be loaded: \(error)")
        }
    }

    private func read(_ raw: [[String]], from origin: String) throws {
        let parsed = try LocalizationTable.parse(raw)
        let resolved = LocalizationTemplate.resolve(parsed, snapshot: snapshot)
        tableEdits = resolved.edits
        tableProblems = resolved.problems
        tableStatus = "\(parsed.count) rows read from \(origin)."
    }

    private func clearTable(_ status: String) {
        tableEdits = []
        tableProblems = []
        tableStatus = status
    }

    /// The template of every product and group, prefilled with today's texts. Returns the number of owners.
    func exportTemplate(to url: URL) throws -> Int {
        let owners = snapshot.owners()
        try Data(LocalizationTemplate.csv(snapshot: snapshot, owners: owners).utf8).write(to: url, options: .atomic)
        return owners.count
    }

    // MARK: Plan

    private var editorEdits: [LocalizationEdit] {
        guard let owner else { return [] }
        return rows.map { row in
            LocalizationEdit(owner: owner, locale: row.locale, name: row.name,
                             description: owner.kind == .group ? nil : row.description,
                             customAppName: owner.kind == .group ? row.customAppName : nil)
        }
    }

    var edits: [LocalizationEdit] { source == .editor ? editorEdits : tableEdits }

    var inputsFingerprint: String {
        let editor = rows.map { "\($0.locale)=\($0.name)|\($0.description)|\($0.customAppName)" }.joined(separator: ";")
        return [source.rawValue, owner?.key ?? "", editor, String(tableEdits.hashValue), String(tableProblems.count)].joined(separator: "#")
    }

    var blockingVerdicts: [Verdict] {
        (draft?.verdicts ?? []).filter { if case .block = $0.severity { return true } else { return false } }
    }

    /// False within the debounce after an edit or an owner switch: the draft then still belongs to the previous inputs.
    var canSave: Bool {
        builtFingerprint == inputsFingerprint
            && (draft.map { !$0.items.isEmpty } ?? false) && lastSpec != nil
            && !(draft?.verdicts ?? []).contains { $0.severity == .block(.plan) }
            && (source == .editor || tableProblems.isEmpty)
    }

    /// Called debounced from the view; never from `body`.
    func rebuild() {
        let fingerprint = inputsFingerprint
        let edits = self.edits
        guard !edits.isEmpty else { draft = nil; lastSpec = nil; buildError = nil; builtFingerprint = fingerprint; return }
        let spec = PlanSpec.localization(LocalizationPlanSpec(edits: edits))
        do {
            draft = try planner.plan(spec, context: PlanningContext(snapshot: snapshot, config: config, today: today))
            lastSpec = spec
            buildError = nil
        } catch {
            draft = nil
            lastSpec = nil
            buildError = String(describing: error)
        }
        builtFingerprint = fingerprint
    }

    /// Stores the Draft through PlanningModel.build and opens the Plan screen. nil on success, else the message to show.
    func save() async -> String? {
        guard canSave, let lastSpec else { return "The plan is not built." }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if await planning.build(lastSpec, reason: trimmed.isEmpty ? nil : trimmed) { return nil }
        let message = planning.errorMessage ?? "The plan cannot be saved."
        planning.errorMessage = nil
        return message
    }
}
