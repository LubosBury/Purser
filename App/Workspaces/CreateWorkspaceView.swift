import SwiftUI
import UniformTypeIdentifiers
import Domain

struct CreateWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = WorkspaceDraft()
    @State private var importingKey = false
    @State private var saving = false
    @State private var error: String?

    /// The six `ws-*` banner colours of the design system, as the hex the workspace stores.
    static let presetColors: [(name: String, hex: String)] = [
        ("Graphite", "#48484D"), ("Blue", "#0062CC"), ("Teal", "#007A6E"),
        ("Green", "#217A36"), ("Amber", "#8F5200"), ("Pink", "#B4235A"),
    ]
    static let p8Type = UTType(filenameExtension: "p8") ?? .data

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bannerPreview
            Text("New workspace")
                .font(PurserFont.title2)
                .padding(PurserSpacing.space5)
            PlanFormScaffold {
                PlanFormStep(1, "App", hint: "The App ID and Bundle ID cannot be changed after creation.") {
                    PlanFormField("Name") { TextField("Name", text: $draft.name) }
                    HStack(alignment: .top, spacing: PurserSpacing.space3) {
                        PlanFormField("App ID (the app's Apple ID in App Store Connect)") {
                            TextField("App ID", text: $draft.appId).font(PurserFont.figure)
                        }
                        PlanFormField("Bundle ID") { TextField("Bundle ID", text: $draft.bundleId).font(PurserFont.figure) }
                    }
                }
                PlanFormStep(2, "Banner") {
                    HStack(spacing: PurserSpacing.space2) {
                        ForEach(Self.presetColors, id: \.hex) { preset in
                            Button { draft.colorHex = preset.hex } label: {
                                RoundedRectangle(cornerRadius: PurserRadius.radiusSm, style: .continuous)
                                    .fill(Color(hex: preset.hex))
                                    .frame(width: PurserSpacing.space8, height: PurserSpacing.space5)
                                    .overlay {
                                        // The selected colour is marked by a check, not by the colour itself.
                                        if draft.colorHex.caseInsensitiveCompare(preset.hex) == .orderedSame {
                                            Image(systemName: "checkmark").font(PurserFont.headline).foregroundStyle(PurserColor.onAccent)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.name)
                            .help(preset.name)
                        }
                        TextField("Color as hex", text: $draft.colorHex)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(PurserFont.figure)
                            .frame(width: 100)
                    }
                    .disabled(draft.isProduction)
                    VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                        Toggle("Production workspace", isOn: $draft.isProduction).toggleStyle(.checkbox)
                        PlanFormHint("The banner is always red with the word PRODUCTION; the app name is typed before every write (C1).")
                    }
                }
                PlanFormStep(3, "App Store Connect API key", hint: "The .p8 content is stored only in this Mac's Keychain. Delete the file from Downloads afterwards.") {
                    Picker("Key type", selection: $draft.keyKind) {
                        Text("Team").tag(KeyKind.team)
                        Text("Individual").tag(KeyKind.individual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    HStack(alignment: .top, spacing: PurserSpacing.space3) {
                        PlanFormField("Key ID") { TextField("Key ID", text: $draft.keyId).font(PurserFont.figure) }
                        if draft.keyKind == .team {
                            PlanFormField("Issuer ID") { TextField("Issuer ID", text: $draft.issuerId).font(PurserFont.figure) }
                        }
                    }
                    HStack(spacing: PurserSpacing.space3) {
                        Button("Choose .p8…") { importingKey = true }.purserButton()
                        Text(draft.keyFileName ?? "No file selected")
                            .font(PurserFont.callout)
                            .foregroundStyle(PurserColor.textSecondary)
                    }
                }
                if !draft.problems.isEmpty || error != nil {
                    VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                        ForEach(draft.problems, id: \.self) { PlanFormMessage($0, kind: .warning) }
                        if let error { PlanFormMessage(error, kind: .danger) }
                    }
                }
            } footer: {
                HStack(spacing: PurserSpacing.space2) {
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .purserButton()
                    Button("Create workspace") { save() }
                        .keyboardShortcut(.defaultAction)
                        .purserButton(primary: true)
                        .disabled(!draft.problems.isEmpty || saving)
                }
            }
        }
        .frame(width: 600, height: 680)
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [Self.p8Type]) { result in
            switch result {
            case let .success(url):
                do {
                    draft.privateKeyPEM = try WorkspaceDraft.readKeyFile(at: url)
                    draft.keyFileName = url.lastPathComponent
                    error = nil
                } catch {
                    self.error = "The file cannot be read: \(error.localizedDescription)"
                }
            case let .failure(failure):
                error = failure.localizedDescription
            }
        }
    }

    /// The banner as it will look in the new workspace.
    private var bannerPreview: some View {
        HStack(spacing: PurserSpacing.space4) {
            Text(draft.name.isEmpty ? "App name" : draft.name).font(PurserFont.headline)
            if draft.isProduction { Text("PRODUCTION").font(PurserFont.headline) }
            Spacer(minLength: 0)
            Text(draft.bundleId).font(PurserFont.identifier).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(PurserColor.onAccent)
        .padding(.horizontal, PurserSpacing.space4)
        .padding(.vertical, PurserSpacing.space2)
        .frame(maxWidth: .infinity)
        .background(draft.isProduction ? PurserColor.dangerFill : Color(hex: draft.colorHex))
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.createWorkspace(draft)
                draft.privateKeyPEM = nil
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
