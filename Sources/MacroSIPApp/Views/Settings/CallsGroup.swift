import SwiftUI
import MacroSIPCore

/// Settings › Calls › During a call (SCREENS.md 8.7): a second call, DTMF method, bring the main window forward.
struct CallsGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FormGroup(header: L.callsHeader) {
            FormRow(label: L.callsIncomingWhileOnCall, help: L.callsIncomingWhileOnCallHelp) {
                Picker("", selection: model.binding(\.callOptions.incomingWhileOnCall)) {
                    Text(L.callsWaiting).tag(IncomingWhileOnCall.callWaiting)
                    Text(L.callsWindowOnly).tag(IncomingWhileOnCall.windowOnly)
                    Text(L.callsBusy).tag(IncomingWhileOnCall.busy)
                }
                .labelsHidden().frame(width: 250)
            }
            FormDivider()
            FormRow(label: L.callsDTMF, help: L.callsDTMFHelp) {
                Picker("", selection: model.binding(\.callOptions.dtmfMethod)) {
                    Text(L.callsDTMFAutomatic).tag(DTMFMethod.automatic)
                    Text("RFC 2833").tag(DTMFMethod.rfc2833)
                    Text("SIP INFO").tag(DTMFMethod.sipINFO)
                    Text(L.callsDTMFInBand).tag(DTMFMethod.inband)
                }
                .labelsHidden().frame(width: 190)
            }
            FormDivider()
            FormRow(label: L.callsBringToFront, help: L.callsBringToFrontHelp) {
                Toggle("", isOn: model.binding(\.general.bringToFrontOnIncoming)).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}
