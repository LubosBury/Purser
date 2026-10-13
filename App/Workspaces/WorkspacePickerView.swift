import SwiftUI
import Store

struct WorkspacePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var creating = false

    var body: some View {
        PurserGateLayout(maxWidth: 520) {
            VStack(alignment: .leading, spacing: PurserSpacing.space4) {
                Text("Choose a workspace")
                    .font(PurserFont.title1)
                    .foregroundStyle(PurserColor.textPrimary)
                storageStatus
                if model.workspaces.isEmpty {
                    ContentUnavailableView("No workspace yet", systemImage: "square.stack.3d.up",
                                           description: Text("A workspace connects one app with its App Store Connect API key."))
                        .frame(minHeight: 200)
                } else {
                    List(model.workspaces, id: \.id, selection: $selection) { entry in
                        HStack(spacing: PurserSpacing.space2) {
                            // The colour repeats the workspace banner; the name carries the meaning.
                            RoundedRectangle(cornerRadius: PurserRadius.radiusSm / 2, style: .continuous)
                                .fill(Color(hex: entry.colorHex))
                                .frame(width: PurserSpacing.space3, height: PurserSpacing.space3)
                                .accessibilityHidden(true)
                            Text(entry.name).font(PurserFont.body)
                        }
                        .tag(entry.id)
                    }
                    // Double-click (and the context menu) opens the workspace; a tap gesture on the List never fires
                    // because the rows take the clicks for selection.
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if let entry = entry(in: ids) { Button("Open") { open(entry) } }
                    } primaryAction: { ids in
                        if let entry = entry(in: ids) { open(entry) }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200, maxHeight: 320)
                    .background(PurserColor.glassFill, in: RoundedRectangle(cornerRadius: PurserRadius.radiusMd, style: .continuous))
                }
                HStack {
                    Button("New workspace…") { creating = true }
                        .purserButton()
                    Spacer()
                    Button("Open") { if let entry = selectedEntry { open(entry) } }
                        .keyboardShortcut(.defaultAction)
                        .purserButton(primary: true)
                        .disabled(selectedEntry == nil)
                }
            }
        }
        .sheet(isPresented: $creating) {
            CreateWorkspaceView()
        }
    }

    @ViewBuilder
    private var storageStatus: some View {
        switch AppPaths.workspaces.status {
        case .appGroup:
            EmptyView()
        case .legacyNoGroup:
            PlanFormMessage("Unsigned build: workspaces live in the app's Application Support and the background nightly sync is off.",
                            kind: .neutral)
        case let .migrationFailed(message):
            PlanFormMessage("Moving the workspaces to the shared container failed: \(message). The data stayed in place; Purser tries again at the next launch.",
                            kind: .danger)
        }
    }

    private var selectedEntry: WorkspaceEntry? {
        model.workspaces.first { $0.id == selection }
    }

    private func entry(in ids: Set<UUID>) -> WorkspaceEntry? {
        model.workspaces.first { ids.contains($0.id) }
    }

    private func open(_ entry: WorkspaceEntry) {
        Task { await model.open(entry) }
    }
}
