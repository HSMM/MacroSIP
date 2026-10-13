import SwiftUI

/// Settings › General › Updates (ADR 0013): automatic checks, release candidates, Check Now.
struct UpdatesGroup: View {
    private let updater = Updater.shared

    var body: some View {
        FormGroup(header: L.updatesHeader, footer: updater.isRunning ? nil : L.updatesUnavailable) {
            FormRow(label: L.updatesAutomatic, help: L.updatesAutomaticHelp) {
                Toggle("", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            FormDivider()
            FormRow(label: L.updatesReleaseCandidates, help: L.updatesReleaseCandidatesHelp) {
                Toggle("", isOn: Binding(get: { updater.includeReleaseCandidates }, set: { updater.includeReleaseCandidates = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            FormDivider()
            FormRow(label: lastCheckText) {
                Button(L.updatesCheckNow) { updater.checkForUpdates() }.disabled(!updater.canCheck)
            }
        }
        .disabled(!updater.isRunning)
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return L.updatesLastCheckNever }
        return L.updatesLastCheck(date.formatted(date: .abbreviated, time: .shortened))
    }
}
