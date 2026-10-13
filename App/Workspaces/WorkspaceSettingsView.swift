import SwiftUI
import UniformTypeIdentifiers
import Domain

/// Workspace settings as glass panels. "Save changes" in the header saves the edited copy of the config; the key and
/// the Slack webhook go to the Keychain with their own buttons.
struct WorkspaceSettingsView: View {
    let session: WorkspaceSession
    /// Editable copy of the config; "Save changes" hands it to `WorkspaceSession.saveConfig(_:)`.
    @State private var config: WorkspaceConfig?
    @State private var keyKind: KeyKind = .team
    @State private var keyId = ""
    @State private var issuerId = ""
    @State private var importingKey = false
    @State private var message: String?
    @State private var keyMessage: String?

    private var hasChanges: Bool { config.map { $0 != session.config } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space4) {
            PurserScreenHeader("Settings") {
                Spacer()
                if let message {
                    Text(message).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary).lineLimit(1)
                } else if hasChanges {
                    Text("Unsaved changes").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                }
                Button("Save changes") { saveSettings() }
                    .purserButton(primary: true)
                    .disabled(!hasChanges)
            }
            ScrollView {
                PurserGlassContainer {
                    VStack(spacing: PurserSpacing.space4) {
                        appPanel
                        if let binding = Binding($config) {
                            operationPanel(binding)
                            SlackSettingsSection(session: session, enabled: binding.slackWebhookEnabled)
                        }
                        keyPanel
                        if let binding = Binding($config) {
                            GoogleSettingsSection(config: binding, google: session.google)
                            ImportMappingEditor(config: binding)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(PurserSpacing.space5)
        .onAppear(perform: load)
        .onChange(of: config) { _, _ in message = nil }
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [CreateWorkspaceView.p8Type]) { result in
            guard case let .success(url) = result else { return }
            Task {
                do {
                    let pem = try WorkspaceDraft.readKeyFile(at: url)
                    try await session.replaceKey(keyKind: keyKind, keyId: keyId, issuerId: keyKind == .team ? issuerId : nil, pem: pem)
                    config = session.config
                    keyMessage = "The key is stored in the Keychain."
                } catch {
                    keyMessage = "The key was not saved: \(error)"
                }
            }
        }
    }

    private var appPanel: some View {
        PurserSettingsPanel("App", hint: "Cannot be changed. Create a new workspace for another app.") {
            VStack(alignment: .leading, spacing: PurserSpacing.space2) {
                PurserKeyValue(label: "Name", value: session.config.name)
                PurserKeyValue(label: "App ID", value: session.config.appId, isIdentifier: true)
                PurserKeyValue(label: "Bundle ID", value: session.config.bundleId, isIdentifier: true)
                PurserKeyValue(label: "Workspace ID", value: session.config.id.uuidString, isIdentifier: true)
            }
        }
    }

    private func operationPanel(_ binding: Binding<WorkspaceConfig>) -> some View {
        PurserSettingsPanel("Operation") {
            VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                Toggle("Production workspace", isOn: binding.isProduction).toggleStyle(.checkbox)
                PlanFormHint("A red banner with the word PRODUCTION; the app name is typed before every write (C1).")
            }
            HStack(spacing: PurserSpacing.space3) {
                Text("Nightly sync").font(PurserFont.body)
                Text("\(binding.wrappedValue.nightlySyncHourUTC):00 UTC").font(PurserFont.figure)
                Stepper("Nightly sync hour", value: binding.nightlySyncHourUTC, in: 0...23).labelsHidden()
            }
        }
    }

    private var keyPanel: some View {
        PurserSettingsPanel("App Store Connect API key", hint: "The .p8 content is stored only in this Mac's Keychain. An import replaces the key at once, without the Save changes button.") {
            PurserKeyValue(label: "Current key", value: "\(session.config.keyKind == .team ? "team" : "individual") \(session.config.keyId)",
                           isIdentifier: true)
            Picker("Key type", selection: $keyKind) {
                Text("Team").tag(KeyKind.team)
                Text("Individual").tag(KeyKind.individual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(alignment: .top, spacing: PurserSpacing.space3) {
                PlanFormField("Key ID") { TextField("Key ID", text: $keyId).font(PurserFont.figure) }
                if keyKind == .team {
                    PlanFormField("Issuer ID") { TextField("Issuer ID", text: $issuerId).font(PurserFont.figure) }
                }
            }
            HStack(spacing: PurserSpacing.space3) {
                Button("Import a new .p8…") { importingKey = true }
                    .purserButton()
                    .disabled(keyId.isEmpty)
                if keyId.isEmpty {
                    Text("Fill in the Key ID first.").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                } else if let keyMessage {
                    Text(keyMessage).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                }
            }
        }
    }

    private func load() {
        config = session.config
        keyKind = session.config.keyKind
        keyId = session.config.keyId
        issuerId = session.config.issuerId ?? ""
    }

    private func saveSettings() {
        guard let config else { return }
        do {
            try session.saveConfig(config)
            self.config = session.config
            message = "Saved and recorded in the audit."
        } catch {
            message = "Not saved: \(error)"
        }
    }
}
