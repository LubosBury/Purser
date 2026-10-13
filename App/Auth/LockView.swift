import SwiftUI

struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PurserGateLayout {
            VStack(spacing: PurserSpacing.space5) {
                Image(systemName: "touchid")
                    .font(.system(size: PurserSpacing.space10))
                    .foregroundStyle(PurserColor.accent)
                    .accessibilityHidden(true)
                VStack(spacing: PurserSpacing.space2) {
                    Text("Purser is locked")
                        .font(PurserFont.title1)
                        .foregroundStyle(PurserColor.textPrimary)
                    Text("Unlock it with Touch ID.")
                        .font(PurserFont.body)
                        .foregroundStyle(PurserColor.textSecondary)
                }
                Button {
                    Task { await model.unlock() }
                } label: {
                    Text("Unlock").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .purserButton(primary: true)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
