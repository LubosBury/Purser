import SwiftUI
import Domain
import PurserSecurity
import Executor

/// Workspace settings (spec §8): the Slack webhook goes straight to the Keychain; the switch edits the settings copy of the
/// config and is saved (and audited) by the settings screen's "Save changes".
struct SlackSettingsSection: View {
    let session: WorkspaceSession
    @Binding var enabled: Bool
    @State private var webhook = ""
    @State private var hasWebhook = false
    @State private var message: String?

    var body: some View {
        PurserSettingsPanel("Slack", hint: "Optional. Purser sends only counts, states, rule IDs and the audit hash: new findings, a finished or paused write and the daily chain fingerprint. Never prices or product IDs.") {
            HStack(spacing: PurserSpacing.space2) {
                Text("Webhook").font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary)
                if hasWebhook {
                    PurserBadge(text: "Stored in the Keychain", kind: .success)
                } else {
                    PurserBadge(text: "Not set")
                }
            }
            PlanFormField("New webhook") {
                SecureField("New webhook", text: $webhook, prompt: Text("https://hooks.slack.com/services/…"))
            }
            HStack(spacing: PurserSpacing.space2) {
                Button("Save webhook") { save(webhook) }
                    .purserButton()
                    .disabled(webhook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Delete webhook") { save(nil) }
                    .purserButton()
                    .disabled(!hasWebhook)
                if let message { Text(message).font(PurserFont.callout).foregroundStyle(PurserColor.textSecondary) }
            }
            VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                Toggle("Send messages to Slack", isOn: $enabled)
                    .toggleStyle(.checkbox)
                    .disabled(!hasWebhook && !enabled)
                PlanFormHint("The Save changes button saves the switch.")
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        hasWebhook = (try? session.secretStore.get(account: SecretAccount.slackWebhook(session.config.id))) != nil
    }

    private func save(_ value: String?) {
        do {
            try session.saveSlackWebhook(value)
            webhook = ""
            message = value == nil ? "Webhook deleted (audit: removed)." : "Webhook saved to the Keychain (audit: set)."
            if value == nil { enabled = false }
            load()
        } catch SlackPublishError.invalidWebhook {
            message = "The webhook must start with https://hooks.slack.com/"
        } catch {
            message = "Not saved: \(error)"
        }
    }
}
