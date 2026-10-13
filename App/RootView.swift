import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var activityMonitor: Any?

    var body: some View {
        Group {
            switch model.phase {
            case .needsOwner:
                OwnerSetupView()
            case .locked:
                LockView()
            case .picking:
                WorkspacePickerView()
            case let .open(session):
                WorkspaceApplyHost(session: session) {
                    WorkspaceShellView(session: session)
                }
                .id(session.entry.id)
            }
        }
        .alert("Purser Pricing", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            guard activityMonitor == nil else { return }
            activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
                MainActor.assumeIsolated { model.noteActivity() }
                return event
            }
        }
    }
}
