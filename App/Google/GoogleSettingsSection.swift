import SwiftUI
import Domain

/// Workspace settings: Google OAuth client id, spreadsheet id and range of the import source, sign-in button.
/// Edits `config`; the settings screen saves it (and audits configChanged) as for any other field.
struct GoogleSettingsSection: View {
    @Binding var config: WorkspaceConfig
    @Bindable var google: GoogleAccount
    @State private var signingIn = false

    var body: some View {
        PurserSettingsPanel("Google Sheets", hint: "The source of the import sheet. The Save changes button saves the fields.") {
            PlanFormField("OAuth client ID (iOS client)") {
                TextField("OAuth client ID", text: Binding(
                    get: { config.googleClientId ?? "" },
                    set: {
                        let trimmed = $0.trimmingCharacters(in: .whitespaces)
                        config.googleClientId = trimmed.isEmpty ? nil : trimmed
                    }))
                    .font(PurserFont.figure)
            }
            if config.importMapping == nil {
                PlanFormHint("The spreadsheet ID and range can be set once the import mapping is saved.")
            } else {
                HStack(alignment: .top, spacing: PurserSpacing.space3) {
                    PlanFormField("Spreadsheet ID") { TextField("Spreadsheet ID", text: sheetBinding(\.spreadsheetId)).font(PurserFont.figure) }
                    PlanFormField("Range") { TextField("Range", text: sheetBinding(\.range), prompt: Text("Prices!A1:K200")).font(PurserFont.figure) }
                        .frame(width: 200)
                }
                Button("Switch the import source to CSV") { config.importMapping?.source = .csv }
                    .purserPlainButton()
            }
            HStack(spacing: PurserSpacing.space3) {
                if google.isSignedIn {
                    PurserBadge(text: "Account signed in", kind: .success)
                } else {
                    PurserBadge(text: "Account not signed in")
                }
                Button(google.isSignedIn ? "Sign in again" : "Sign in with Google") {
                    guard let clientId = config.googleClientId else { return }
                    signingIn = true
                    Task {
                        await google.signIn(clientId: clientId)
                        signingIn = false
                    }
                }
                .purserButton()
                .disabled(config.googleClientId == nil || signingIn)
                if signingIn { ProgressView().controlSize(.small) }
            }
            if let error = google.lastError { PlanFormMessage(error, kind: .danger) }
        }
    }

    private struct SheetSource { var spreadsheetId: String; var range: String }

    private func sheetBinding(_ keyPath: WritableKeyPath<SheetSource, String>) -> Binding<String> {
        Binding(
            get: {
                guard case let .googleSheet(id, range) = config.importMapping?.source else { return "" }
                return SheetSource(spreadsheetId: id, range: range)[keyPath: keyPath]
            },
            set: { newValue in
                var source = SheetSource(spreadsheetId: "", range: "")
                if case let .googleSheet(id, range) = config.importMapping?.source { source = SheetSource(spreadsheetId: id, range: range) }
                source[keyPath: keyPath] = newValue.trimmingCharacters(in: .whitespaces)
                config.importMapping?.source = .googleSheet(spreadsheetId: source.spreadsheetId, range: source.range)
            })
    }
}
