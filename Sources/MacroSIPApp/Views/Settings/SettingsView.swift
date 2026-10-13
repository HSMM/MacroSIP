import SwiftUI

/// Screen 8: toolbar tabs, changes apply immediately. Nine tabs.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralPane()
                .tabItem { Label(L.settingsGeneral, systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AccountsPane()
                .tabItem { Label(L.settingsAccounts, systemImage: "person.crop.circle") }
                .tag(SettingsTab.accounts)
            AudioPane()
                .tabItem { Label(L.settingsAudio, systemImage: "speaker.wave.2") }
                .tag(SettingsTab.audio)
            NetworkPane()
                .tabItem { Label(L.settingsNetwork, systemImage: "network") }
                .tag(SettingsTab.network)
            CodecsPane()
                .tabItem { Label(L.settingsCodecs, systemImage: "waveform") }
                .tag(SettingsTab.codecs)
            RecordingPane()
                .tabItem { Label(L.settingsRecording, systemImage: "record.circle") }
                .tag(SettingsTab.recording)
            AutoAnswerPane()
                .tabItem { Label(L.settingsCalls, systemImage: "phone.badge.waveform") }
                .tag(SettingsTab.calls)
            QuickKeysPane()
                .tabItem { Label(L.quickKeysTitle, systemImage: "square.grid.3x3") }
                .tag(SettingsTab.quickKeys)
            DirectoryPane()
                .tabItem { Label(L.directoryTitle, systemImage: "book") }
                .tag(SettingsTab.directory)
        }
        .frame(width: 680)
    }
}
