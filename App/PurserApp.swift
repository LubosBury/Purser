import SwiftUI

@main
struct PurserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(environment: .live())
    @State private var backgroundSync = BackgroundSyncCoordinator()

    var body: some Scene {
        WindowGroup("Purser Pricing") {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                .task { await model.launch() }
                .task { backgroundSync.refresh() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Lock Purser") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
            }
            #if DEBUG
            DebugCommands(model: model)
            #endif
        }
        Settings {
            AppSettingsView(coordinator: backgroundSync)
                .environment(model)
        }
        #if DEBUG
        Window("Spike console", id: "spike-console") {
            SpikeConsoleView()
                .environment(model)
        }
        #endif
    }
}
