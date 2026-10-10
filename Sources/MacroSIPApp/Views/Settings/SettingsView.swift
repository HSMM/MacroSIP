import SwiftUI

/// Screen 8: toolbar tabs, changes apply immediately. Lite has five tabs.
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
            // [Full] Recording and Auto-answer tabs are intentionally absent in Lite.
        }
        .frame(width: 620)
    }
}
