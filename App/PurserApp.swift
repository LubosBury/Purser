import SwiftUI

@main
struct PurserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var backgroundSync = BackgroundSyncCoordinator()
    @State private var mcpBridge: MCPBridgeHost

    init() {
        let model = AppModel(environment: .live())
        _model = State(initialValue: model)
        _mcpBridge = State(initialValue: MCPBridgeHost(model: model))
    }

    var body: some Scene {
        WindowGroup("Purser Pricing") {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                // Date pickers and interpolated numbers follow the en_US UI, not the system locale.
                .environment(\.locale, Locale(identifier: "en_US"))
                .task { await model.launch() }
                .task { backgroundSync.refresh() }
                .task { mcpBridge.refresh() }
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
            AppSettingsView(coordinator: backgroundSync, mcpBridge: mcpBridge)
                .environment(model)
                .environment(\.locale, Locale(identifier: "en_US"))
        }
        #if DEBUG
        Window("Spike console", id: "spike-console") {
            SpikeConsoleView()
                .environment(model)
                .environment(\.locale, Locale(identifier: "en_US"))
        }
        #endif
    }
}
