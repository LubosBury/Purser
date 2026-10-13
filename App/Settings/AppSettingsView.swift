import AppKit
import SwiftUI

struct AppSettingsView: View {
    @Bindable var coordinator: BackgroundSyncCoordinator
    var mcpBridge: MCPBridgeHost
    @State private var mcpMessage: String?
    @Environment(AppModel.self) private var model
    /// The edited name; nil while the field shows the saved one.
    @State private var ownerDraft: String?
    @State private var ownerMessage: String?
    @State private var window: NSWindow?
    @State private var renaming = false

    var body: some View {
        VStack(spacing: PurserSpacing.space4) {
            ownerPanel
            syncPanel
            mcpPanel
            actionBar
        }
        // Full height even while a message is shown under the name; otherwise the window squeezes the last row.
        .fixedSize(horizontal: false, vertical: true)
        .padding(PurserSpacing.space5)
        .frame(width: 600)
        .background(PurserStage())
        .preferredColorScheme(.dark)
        .background(SettingsWindowReader(window: $window))
        .onAppear { coordinator.refresh() }
    }

    private var ownerUnlocked: Bool {
        switch model.phase {
        case .picking, .open: return true
        case .needsOwner, .locked: return false
        }
    }

    private var ownerChanged: Bool {
        guard let ownerDraft else { return false }
        return ownerDraft.trimmingCharacters(in: .whitespacesAndNewlines) != model.ownerName
    }

    private var ownerPanel: some View {
        PurserSettingsPanel("Name in the audit",
                            hint: "Purser records your actions in the audit under this name. Older records keep the name they were made under. Changing it requires Touch ID.") {
            PlanFormField("Name") {
                TextField("Name", text: Binding(
                    get: { ownerDraft ?? model.ownerName ?? "" },
                    set: { ownerDraft = $0; ownerMessage = nil }))
                    .disabled(!ownerUnlocked || renaming)
            }
            if !ownerUnlocked {
                PlanFormMessage("The name can be changed only while Purser is unlocked.", kind: .warning)
            } else if let ownerMessage {
                PlanFormMessage(ownerMessage, kind: .danger)
            }
        }
    }

    /// The name is the only field that waits for a save; the sync toggle applies at once.
    private var actionBar: some View {
        HStack(spacing: PurserSpacing.space2) {
            Spacer()
            if ownerChanged {
                Button("Cancel", action: close)
                .purserButton()
                .keyboardShortcut(.cancelAction)
                .disabled(renaming)
                Button("Save and close", action: saveAndClose)
                    .purserButton(primary: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ownerUnlocked || renaming)
            } else {
                Button("Close", action: close)
                    .purserButton(primary: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func saveAndClose() {
        guard ownerUnlocked, ownerChanged, !renaming else { return }
        renaming = true
        Task {
            ownerMessage = await model.renameOwner(to: ownerDraft ?? "")
            renaming = false
            if ownerMessage == nil { close() }
        }
    }

    /// Drops an unsaved name, so the next opening shows the saved one.
    private func close() {
        ownerDraft = nil
        ownerMessage = nil
        window?.close()
    }

    private var mcpPanel: some View {
        PurserSettingsPanel("Claude (MCP)",
                            hint: "Lets an MCP client on this Mac, such as Claude Desktop, read the open workspace and prepare plans while Purser is unlocked. Every call that changes something is in the audit.") {
            VStack(alignment: .leading, spacing: PurserSpacing.space2) {
                Toggle("Let Claude control Purser", isOn: Binding(
                    get: { mcpBridge.isEnabled },
                    set: { mcpBridge.setEnabled($0) }))
                    .toggleStyle(.checkbox)
                Toggle("Apply plans and create products without Touch ID", isOn: Binding(
                    get: { mcpBridge.writesWithoutTouchID },
                    set: { allowed in Task { mcpMessage = await mcpBridge.setWritesWithoutTouchID(allowed) } }))
                    .toggleStyle(.checkbox)
                    .disabled(!mcpBridge.isEnabled)
                if mcpBridge.writesWithoutTouchID {
                    HStack(alignment: .firstTextBaseline, spacing: PurserSpacing.space2) {
                        PurserBadge(text: "WARN", kind: .warning)
                        Text("Claude can change live prices without you confirming at this Mac. Price changes of approved products take effect without App Review.")
                            .font(PurserFont.callout)
                            .foregroundStyle(PurserColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let mcpMessage { PlanFormMessage(mcpMessage, kind: .danger) }
            }
            Divider().overlay(PurserColor.separator)
            VStack(alignment: .leading, spacing: PurserSpacing.space2) {
                PurserKeyValue(label: "Bridge", value: mcpBridge.statusText)
                PurserKeyValue(label: "Command", value: MCPBridgeHost.helperPath, isIdentifier: true)
                Button("Copy the Claude Desktop configuration") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MCPBridgeHost.clientConfiguration, forType: .string)
                }
                .purserButton()
            }
        }
    }

    private var syncPanel: some View {
        PurserSettingsPanel("Nightly sync",
                            hint: "The sync hour (UTC) is set per workspace. The background sync only reads; it never writes to App Store Connect.") {
            VStack(alignment: .leading, spacing: PurserSpacing.space2) {
                Toggle("Run the nightly sync in the background (login item)", isOn: Binding(
                    get: { coordinator.loginItemEnabled || coordinator.status == .requiresApproval },
                    set: { coordinator.setLoginItemEnabled($0) }))
                    .toggleStyle(.checkbox)
                if coordinator.status == .requiresApproval {
                    HStack(spacing: PurserSpacing.space2) {
                        PurserBadge(text: "Waiting for approval", kind: .warning)
                        Button("Open Login Items") { coordinator.openLoginItemsSettings() }
                            .purserButton()
                    }
                }
                if let error = coordinator.lastError { PlanFormMessage(error, kind: .danger) }
            }
            Divider().overlay(PurserColor.separator)
            VStack(alignment: .leading, spacing: PurserSpacing.space2) {
                PurserKeyValue(label: "Login item", value: coordinator.statusText)
                PurserKeyValue(label: "Inside the app", value: coordinator.inAppActive
                    ? "runs at launch and every hour while the app is running"
                    : "off; the login item handles the nightly sync")
                PurserKeyValue(label: "Workspace storage", value: coordinator.rootDescription, isIdentifier: true)
            }
        }
    }
}

/// The Settings scene has no dismiss action; this hands the view its window so the buttons can close it.
private struct SettingsWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window == nil { DispatchQueue.main.async { window = view.window } }
    }
}
