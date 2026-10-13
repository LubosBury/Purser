import SwiftUI
import Planner

struct PromoCoverageMeter: View {
    let coverage: PromoCoverage

    var body: some View {
        PlanFormStep("Territory coverage (O3)") {
            VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                HStack {
                    Text(coverage.isComplete ? "Covered " : "Missing prices ").foregroundStyle(PurserColor.textSecondary)
                        + Text("\(coverage.covered) z \(coverage.required)").bold().foregroundStyle(PurserColor.textPrimary)
                    Spacer()
                }
                .font(PurserFont.callout)
                .monospacedDigit()
                ProgressView(value: Double(min(coverage.covered, coverage.required)), total: Double(max(coverage.required, 1)))
                    .progressViewStyle(.linear)
                    .tint(coverage.isComplete ? PurserColor.accent : PurserColor.warning)
                    .accessibilityLabel("Territory coverage")
            }
            if !coverage.missing.isEmpty {
                PlanFormMessage("Missing price: " + coverage.missing.map(\.rawValue).joined(separator: ", "), kind: .danger)
            }
            if !coverage.outsideAvailability.isEmpty {
                PlanFormMessage("Outside the subscription's availability: " + coverage.outsideAvailability.map(\.rawValue).joined(separator: ", "), kind: .warning)
            }
        }
    }
}
