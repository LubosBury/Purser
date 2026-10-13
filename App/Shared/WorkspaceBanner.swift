import SwiftUI
import Domain

/// Full-width bar in the workspace colour (red for production) with app, key kind/id and app id (spec §8).
struct WorkspaceBanner: View {
    let config: WorkspaceConfig

    var body: some View {
        HStack(spacing: PurserSpacing.space4) {
            Text(config.name)
                .font(PurserFont.headline)
                .layoutPriority(1)
            if config.isProduction {
                // Production is never signalled by the red fill alone.
                Text("PRODUCTION")
                    .font(PurserFont.headline)
            }
            Spacer(minLength: 0)
            Group {
                Text("key \(config.keyKind == .team ? "team" : "individual") \(config.keyId)")
                Text("app \(config.appId)")
                Text(config.bundleId)
            }
            .font(PurserFont.identifier)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .lineLimit(1)
        .foregroundStyle(PurserColor.onAccent)
        .padding(.horizontal, PurserSpacing.space4)
        .padding(.vertical, PurserSpacing.space2)
        .frame(maxWidth: .infinity)
        .background(config.isProduction ? PurserColor.dangerFill : Color(hex: config.colorHex))
    }
}
