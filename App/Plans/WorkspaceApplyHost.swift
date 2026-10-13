import SwiftUI

/// Shows the session's ApplyController for the open workspace: paused-plan banner, confirmation sheet, daily chain head.
struct WorkspaceApplyHost<Content: View>: View {
    let session: WorkspaceSession
    let content: Content

    init(session: WorkspaceSession, @ViewBuilder content: () -> Content) {
        self.session = session
        self.content = content()
    }

    var body: some View {
        let controller = session.applyController
        @Bindable var broker = controller.broker
        // The banner goes below the content: stacking it above would push the split view off the window toolbar.
        content
            .safeAreaInset(edge: .bottom, spacing: 0) { PausedPlansBanner(session: session, controller: controller) }
        .environment(controller)
        .modifier(DrillToolbar(session: session))
        .sheet(item: $broker.pending, onDismiss: { broker.cancelIfWaiting() }) { pending in
            ConfirmationSheet(request: pending.request, config: session.config,
                              changeCount: (try? session.planStore.items(planId: pending.request.planId))?.count ?? 0) { response in
                broker.answer(response)
            }
        }
        .onAppear { ApplyController.current = controller }
        // The inactivity lock, Cmd-Ctrl-L or a workspace switch removes this view: a parked confirmation must not hang the apply.
        .onDisappear { controller.broker.cancelIfWaiting() }
        .task { await ChainHeadScheduler(session: session).run() }
    }
}

/// The S8 drill button exists only in Debug builds.
private struct DrillToolbar: ViewModifier {
    let session: WorkspaceSession

    func body(content: Content) -> some View {
        #if DEBUG
        content.toolbar { ToolbarItem { DrillButton(session: session) } }
        #else
        content
        #endif
    }
}
