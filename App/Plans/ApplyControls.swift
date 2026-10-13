import SwiftUI
import Domain

/// The action bar of the Plan screen: what Apply will do and the one main action for the plan's state, plus the
/// progress of a running or paused apply in the same place.
struct ApplyControls: View {
    let planId: String
    let planState: PlanState
    let changeCount: Int
    let excludedCount: Int
    @Environment(ApplyController.self) private var controller
    @State private var confirmAbort = false
    @State private var confirmWithdraw = false
    @State private var askCloseReason = false
    @State private var closeReason = ""

    private var isActive: Bool { controller.activePlanId == planId }
    private var closeReasonIsBlank: Bool { closeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var busy: Bool { controller.isWorking || controller.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space3) {
            if isActive { ApplyProgressView() }
            HStack(spacing: PurserSpacing.space2) {
                Text(controller.actionMessage ?? summary)
                    .font(PurserFont.body)
                    .foregroundStyle(PurserColor.textSecondary)
                Spacer()
                buttons
            }
        }
        .confirmationDialog("Abort the write?", isPresented: $confirmAbort) {
            Button("Abort the write", role: .destructive) { controller.abort(planId: planId) }
        } message: {
            Text("Requests in flight are read back first. Items already written stay written.")
        }
        .confirmationDialog("Roll back the written changes?", isPresented: $confirmWithdraw) {
            Button("Create a rollback plan") { controller.withdraw(planId: planId) }
        } message: {
            Text("This creates a new Rollback plan (a draft) that deletes the written rows with a future date. Nothing is written to App Store Connect until you apply it.")
        }
        .sheet(isPresented: $askCloseReason) { closeSheet }
    }

    /// States what the bar's main action will do, in numbers.
    private var summary: String {
        switch planState {
        case .draft:
            let excluded = excludedCount == 0 ? "" : " \(excludedCount) excluded cells stay unchanged."
            return "\(changeCount) changes will be written to App Store Connect.\(excluded)"
        case .stale: return "The catalog has changed since the plan was built. Replan it before you apply it."
        case .applying: return controller.isRunning ? "" : "The write is paused."
        case .scheduled: return "The changes are written and wait for their effective date."
        case .partiallyApplied: return "Some changes are written. Replan the rest, roll back, or close the plan."
        case .effective: return "The changes are in effect."
        case .closed: return "The plan is closed."
        case .cancelled: return "The plan is cancelled."
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if planState == .applying || isActive {
            Button("Abort", role: .destructive) { confirmAbort = true }
                .purserButton()
                .tint(PurserColor.dangerFill)
        }
        if isActive, controller.isRunning {
            Button("Pause") { controller.pause() }.purserButton()
        }
        if planState == .applying, !controller.isRunning {
            Button("Continue") { controller.resume(planId: planId) }.purserButton(primary: true)
        }
        if planState == .draft {
            Button("Apply \(changeCount) changes…") { controller.apply(planId: planId) }
                .controlSize(.large)
                .purserButton(primary: true)
                .disabled(controller.isRunning || changeCount == 0)
        }
        if planState == .scheduled {
            Button("Roll back…") { confirmWithdraw = true }.purserButton().disabled(busy)
        }
        if planState == .partiallyApplied {
            Button("Close…") {
                closeReason = ""
                askCloseReason = true
            }
            .purserButton()
            .disabled(controller.isWorking)
            Button("Roll back written…") { confirmWithdraw = true }.purserButton().disabled(busy)
            Button("Replan the rest") { controller.replanRest(planId: planId) }.purserButton(primary: true).disabled(busy)
        }
    }

    private var closeSheet: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space4) {
            Text("Close plan").font(PurserFont.title2)
            Text("Changes not yet written will not be applied.").font(PurserFont.body).foregroundStyle(PurserColor.textSecondary)
            VStack(alignment: .leading, spacing: PurserSpacing.space1) {
                Text("Reason").font(PurserFont.headline).foregroundStyle(PurserColor.textSecondary)
                TextField("Reason", text: $closeReason).labelsHidden().textFieldStyle(.roundedBorder)
                Text("Required. Saved to the audit.").font(PurserFont.footnote).foregroundStyle(PurserColor.textTertiary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { askCloseReason = false }
                    .keyboardShortcut(.cancelAction)
                    .purserButton()
                Button("Close plan") {
                    controller.closePlan(planId: planId, reason: closeReason)
                    askCloseReason = false
                }
                .purserButton(primary: true)
                .disabled(closeReasonIsBlank)
            }
        }
        .padding(PurserSpacing.space5)
        .frame(width: 440)
    }
}

/// Labelled progress of the active apply (docs/design/components/ProgressBar.md): always the numbers, and the pause
/// reason in words when it has stopped.
struct ApplyProgressView: View {
    @Environment(ApplyController.self) private var controller

    private var isPaused: Bool {
        if case .paused = controller.phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PurserSpacing.space1) {
            HStack {
                Text("\(status) ").foregroundStyle(PurserColor.textSecondary)
                    + Text("\(controller.done) z \(controller.total)").bold().foregroundStyle(PurserColor.textPrimary)
                Spacer()
                if let eta = controller.etaMinutes, !isPaused {
                    Text("about \(eta) min left").foregroundStyle(PurserColor.textSecondary)
                }
            }
            .font(PurserFont.callout)
            .monospacedDigit()
            ProgressView(value: Double(controller.done), total: Double(max(controller.total, 1)))
                .progressViewStyle(.linear)
                .tint(isPaused ? PurserColor.warning : PurserColor.accent)
                .accessibilityLabel("Write progress")
            if let remaining = controller.budgetRemaining {
                Text("hourly request limit: \(remaining) left")
                    .font(PurserFont.identifier)
                    .foregroundStyle(PurserColor.textTertiary)
            }
        }
    }

    private var status: String {
        switch controller.phase {
        case .idle: return ""
        case .running: return "Writing"
        case let .paused(_, reason): return "Paused: \(reason.rawValue.uppercased())"
        case let .finished(_, state): return "Finished (\(state.rawValue))"
        case let .failed(_, message): return "Failed: \(message)"
        }
    }
}
