import SwiftUI

/// First launch: asks for the name the audit records as actor.
struct OwnerSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var name = NSFullUserName()
    @State private var working = false

    var body: some View {
        PurserGateLayout {
            VStack(spacing: PurserSpacing.space5) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: PurserSpacing.space10))
                    .foregroundStyle(PurserColor.accent)
                    .accessibilityHidden(true)
                VStack(spacing: PurserSpacing.space2) {
                    Text("Purser Pricing")
                        .font(PurserFont.title1)
                        .foregroundStyle(PurserColor.textPrimary)
                    Text("Enter the name Purser records your actions under in the audit. You can change it in Settings. Access is guarded by Touch ID.")
                        .font(PurserFont.body)
                        .foregroundStyle(PurserColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PlanFormField("Name for the audit") {
                    TextField("Name for the audit", text: $name)
                }
                Button {
                    working = true
                    Task {
                        await model.setOwner(name: name)
                        working = false
                    }
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .purserButton(primary: true)
                .keyboardShortcut(.defaultAction)
                .disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if working { ProgressView().controlSize(.small) }
            }
        }
    }
}
