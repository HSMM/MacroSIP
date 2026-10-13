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
        CommandGroup(replacing: .appInfo) {
            Button(L.menuAbout(model.appName)) { AboutPanel.show() }
            Button(L.updatesMenuCheck) { Updater.shared.checkForUpdates() }.disabled(!Updater.shared.canCheck)
        }
        CommandGroup(replacing: .newItem) {}
        CommandMenu(L.menuCall) {
            Button(L.menuEndCall) { model.endCurrentCall() }
                .keyboardShortcut("d", modifiers: .command)
            Button(L.menuToggleMute) { model.toggleMuteCurrent() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button(L.menuVolumeUp) { model.volumeShortcut(up: true) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.liveCalls.isEmpty)
            Button(L.menuVolumeDown) { model.volumeShortcut(up: false) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.liveCalls.isEmpty)
            Divider()
            Button(L.menuDND) { model.toggleDND() }
                .keyboardShortcut("d", modifiers: [.command, .option])
        }
        CommandGroup(before: .toolbar) {
            // Placeholder: `QuickKeysMenu` hides it and puts the real, validated items (View › Show Quick Keys,
            // Call › Quick keys › ⌘1…⌘9) in its place; SwiftUI would not refresh them when the keys change.
            Button(L.quickKeysShow) {}
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
