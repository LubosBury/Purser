import SwiftUI
import Domain

struct WorkspaceShellView: View {
    @Environment(AppModel.self) private var model
    let session: WorkspaceSession
    @State private var screen: Screen = .catalog
    @State private var newPlan: NewPlanRequest?

    enum Screen: String, Identifiable {
        case catalog = "Catalog"
        case findings = "Findings"
        case plans = "Plans"
        case history = "History"
        case settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .catalog: return "tablecells"
            case .findings: return "flag"
            case .plans: return "list.bullet.clipboard"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    private var planning: PlanningModel { session.planning }

    /// Plans that wait for the user: paused, stale or partially applied.
    private var plansNeedingAttention: Int {
        planning.plans.filter { $0.pauseReason != nil || $0.state == .stale || $0.state == .partiallyApplied }.count
    }

    var body: some View {
        // The split view is the root of the window so its toolbar zone is the window toolbar. With anything stacked
        // above it, the top strip of the detail column is drawn under the toolbar material and its controls disappear.
        NavigationSplitView {
            List(selection: $screen) {
                Section("Prices") {
                    row(.catalog)
                    row(.findings, badge: planning.findingGroups.count)
                    row(.plans, badge: plansNeedingAttention)
                }
                Section("Records") { row(.history) }
                Section("Workspace") { row(.settings) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            VStack(spacing: 0) {
                WorkspaceBanner(config: session.config)
                Group {
                    switch screen {
                    case .catalog: CatalogView(session: session, onNewPlan: startNewPlan, onEditTexts: editTexts)
                    case .findings: FindingsView(model: planning) { prefill in newPlan = NewPlanRequest(prefill: prefill) }
                    case .plans: PlanningRootView(model: planning, onNewPlan: startNewPlan)
                    case .history: HistoryView(session: session)
                    case .settings: WorkspaceSettingsView(session: session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(PurserStage())
        }
        .sheet(item: $newPlan) { request in
            NewPlanSheet(model: planning, prefill: request.prefill, localizationOwner: request.localizationOwner, tab: request.tab)
        }
        // A built or opened plan (New plan sheet, History, showPlan) always lands on the Plans screen.
        .onChange(of: planning.shownPlanId) { _, id in
            if id != nil { screen = .plans }
        }
        .task { await session.reloadCatalog() }
        .task { await planning.reload() }
        .alert("Workspace", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .alert("Plan", isPresented: Binding(get: { planning.errorMessage != nil }, set: { if !$0 { planning.errorMessage = nil } })) {
            Button("OK", role: .cancel) { planning.errorMessage = nil }
        } message: {
            Text(planning.errorMessage ?? "")
        }
    }

    /// The badge goes inside the tag: a row with `.badge` applied after `.tag` cannot be selected.
    private func row(_ item: Screen, badge: Int = 0) -> some View {
        Label(item.rawValue, systemImage: item.symbol)
            .badge(badge)
            .tag(item)
    }

    private func startNewPlan() {
        newPlan = NewPlanRequest(prefill: nil)
    }

    private func editTexts(_ owner: LocalizationOwner?) {
        newPlan = NewPlanRequest(prefill: nil, tab: .localization, localizationOwner: owner)
    }

    // MARK: Sync status and workspace actions

    private var syncDisabled: Bool { session.isSyncing || session.syncBlockedReason != nil }

    private var snapshotLine: String {
        guard let snapshot = session.snapshot else { return "No sync yet" }
        return "Snapshot #\(snapshot.syncId) · \(Formatting.age(since: snapshot.takenAt))"
    }

    /// Technical detail of the last sync; shown on hover so the sidebar stays quiet.
    private var syncDetail: String {
        var parts: [String] = []
        if let result = session.lastSync {
            parts.append("Last sync: \(result.status.rawValue), \(result.requestCount) requests, \(result.newFindings.count) new findings")
        }
        if let rate = session.rateLimit { parts.append("Hourly limit: \(rate.remaining) of \(rate.limit) left") }
        return parts.joined(separator: "\n")
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space2) {
            Text("Data from App Store Connect")
                .font(PurserFont.subheadline)
                .foregroundStyle(PurserColor.textTertiary)
            Text(snapshotLine)
                .font(PurserFont.callout)
                .lineLimit(1)
                .foregroundStyle(PurserColor.textSecondary)
                .help(syncDetail)
            if session.isSyncing {
                HStack(spacing: PurserSpacing.space2) {
                    ProgressView().controlSize(.small)
                    Text("\(session.syncRequestCount) requests").font(PurserFont.figure)
                }
            }
            if let reason = session.syncBlockedReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(PurserFont.callout)
                    .foregroundStyle(PurserColor.warning)
            }
            Button("Sync") { Task { await session.syncNow() } }
                .controlSize(.small)
                .purserButton()
                .disabled(syncDisabled)
            VStack(alignment: .leading, spacing: PurserSpacing.space2) {
                Button("Switch workspace") { model.leaveWorkspace() }
                Button("Lock") { model.lock() }
            }
            .font(PurserFont.callout)
            .purserPlainButton()
            .padding(.top, PurserSpacing.space1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PurserSpacing.space3)
    }
}
