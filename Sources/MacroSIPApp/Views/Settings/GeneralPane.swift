import SwiftUI
import AppKit

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Local private var otherHandler = false
    @Local private var showRestart = false

    private var languageSelection: Binding<String> {
        Binding(
            get: { model.settings.general.language ?? "system" },
            set: { v in
                let new: String? = v == "system" ? nil : v
                guard new != model.settings.general.language else { return }
                model.updateSettings { $0.general.language = new }
                if let new { UserDefaults.standard.set([new], forKey: "AppleLanguages") }
                else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                showRestart = true
            })
    }

    var body: some View {
        PaneContainer {
            FormGroup {
                FormRow(label: L.launchAtLogin, help: loginItemHelp) {
                    if model.loginItemNeedsApproval {
                        Button(L.launchAtLoginOpenSettings) { model.openLoginItemsSettings() }
                    }
                    Toggle("", isOn: model.binding(\.general.launchAtLogin)).labelsHidden().toggleStyle(.switch)
                }
                FormDivider()
                FormRow(label: L.keepRunning) {
                    Toggle("", isOn: model.binding(\.general.keepRunningInMenuBar)).labelsHidden().toggleStyle(.switch)
                }
                FormDivider()
                FormRow(label: L.showInDock) {
                    Toggle("", isOn: model.binding(\.general.showDockIcon)).labelsHidden().toggleStyle(.switch)
                }
            }
            FormGroup(footer: L.languageFooter) {
                FormRow(label: L.language, help: L.languageHelp) {
                    Picker("", selection: languageSelection) {
                        Text(L.languageSystem(systemLanguageName)).tag("system")
                        Text("English").tag("en")
                        Text("Русский").tag("ru")
                    }
                    .labelsHidden().frame(width: 190)
                }
            }
            FormGroup(header: L.linksHeader) {
                FormRow(label: L.linksTitle, help: otherHandler ? L.linksOtherHandler : L.linksIsDefault) {
                    Button(L.linksMakeDefault) { makeDefault() }.disabled(!otherHandler)
                }
                FormDivider()
                FormRow(label: L.linksOnOpen, help: L.linksOnOpenHelp) {
                    Picker("", selection: Binding(get: { model.linkOpenMode }, set: { model.linkOpenMode = $0 })) {
                        Text(L.linksAsk).tag(LinkOpenMode.ask)
                        Text(L.linksCallNow).tag(LinkOpenMode.callImmediately)
                        Text(L.linksFillOnly).tag(LinkOpenMode.fillOnly)
                    }
                    .labelsHidden().frame(width: 190)
                }
            }
            FormGroup(header: L.troubleshootingHeader) {
                FormRow(label: L.logFileTitle, help: L.logFileHelp) {
                    Button(L.logOpenFolder) { model.openLogFolder() }
                }
                FormDivider()
                FormRow(label: L.diagnosticsTitle, help: L.diagnosticsHelp) {
                    Button(L.diagnosticsCopy) { model.copyDiagnostics() }
                }
            }
        }
        .onAppear { refreshHandler(); model.syncLoginItemStatus() }
        .alert(L.languageRestartTitle, isPresented: $showRestart) {
            Button(L.languageRestartNow) { relaunch() }
            Button(L.languageRestartLater, role: .cancel) {}
        } message: { Text(L.languageRestartBody) }
    }

    private var loginItemHelp: String? {
        model.loginItemError ?? (model.loginItemNeedsApproval ? L.launchAtLoginApproval : nil)
    }

    private var systemLanguageName: String {
        // The system's own list: the app's AppleLanguages override (set by the picker below) must not leak into this label.
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        let code = system?.first ?? Locale.preferredLanguages.first ?? "en"
        return (Locale.current.localizedString(forLanguageCode: String(code.prefix(2))) ?? "English").capitalized
    }

    private func refreshHandler() {
        let me = Bundle.main.bundleURL.standardizedFileURL
        otherHandler = ["tel:", "sip:"].contains { s in
            guard let url = URL(string: s), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return true }
            return app.standardizedFileURL != me
        }
    }

    private func makeDefault() {
        Task {
            for scheme in ["sip", "sips", "tel"] {
                do { try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) }
                catch { model.report(error); break }
            }
            refreshHandler()
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
