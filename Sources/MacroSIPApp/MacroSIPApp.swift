import SwiftUI
import MacroSIPCore

@main
struct MacroSIPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        // Single instance, fixed 340x520 content (SCREENS.md "Common main-window frame").
        Window(L.mainTitle, id: "main") {
            MainWindowView()
                .environment(model)
                .background(MainWindowAccessor(model: model))
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu(L.menuCall) {
            Button(L.menuEndCall) { model.endCurrentCall() }
                .keyboardShortcut("d", modifiers: .command)
            Button(L.menuToggleMute) { model.toggleMuteCurrent() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button(L.menuDND) { model.toggleDND() }
                .keyboardShortcut("d", modifiers: [.command, .option])
        }
        CommandGroup(after: .windowArrangement) {
            Button(L.menuShowApp(model.appName)) { model.showMainWindow() }
                .keyboardShortcut("0", modifiers: .command)
        }
        #if DEBUG
        CommandGroup(after: .help) {
            Button(L.menuSimulateIncoming) { DemoState.simulateIncoming(model) }
        }
        #endif
    }
}
